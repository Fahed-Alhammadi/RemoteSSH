import { Transform, type TransformCallback } from 'node:stream'
import type { ChmodAnswer, FileEntry, LogKind, OverwriteAnswer, PromptRequest, Site, TrustAnswer } from '../../shared/types'

export class SessionError extends Error {}
/** The user cancelled (a transfer, a password prompt, an untrusted host key): never retried. */
export class CancelledError extends SessionError {
  constructor(message = 'Interrupted by user') {
    super(message)
  }
}
/** The server or the local disk refused the operation (permission, missing file, quota, login): not retried. */
export class PermanentError extends SessionError {}

/** Local file errors that another attempt can't fix. */
const PERMANENT_ERRNO = new Set(['ENOENT', 'EACCES', 'EPERM', 'ENOSPC', 'EDQUOT', 'EISDIR', 'ENOTDIR', 'EROFS', 'ENAMETOOLONG', 'EEXIST'])
/** SFTP status codes: NO_SUCH_FILE, PERMISSION_DENIED, FAILURE, BAD_MESSAGE, OP_UNSUPPORTED. */
const PERMANENT_SFTP = new Set([2, 3, 4, 5, 8])

/** True for errors a retry can't fix; connection problems (timeouts, resets, closed sockets) are false. */
export function isPermanentError(e: unknown): boolean {
  if (e instanceof PermanentError) return true
  const code = (e as { code?: unknown } | null)?.code
  return (typeof code === 'string' && PERMANENT_ERRNO.has(code)) || (typeof code === 'number' && PERMANENT_SFTP.has(code))
}

/** Wraps an error from ssh2 or the file system, keeping whether it is permanent. */
export function sessionError(e: unknown): SessionError {
  if (e instanceof SessionError) return e
  const message = e instanceof Error ? e.message : String(e)
  return isPermanentError(e) ? new PermanentError(message) : new SessionError(message)
}

export type LogSink = (kind: LogKind, text: string) => void
export type ProgressHandler = (transferred: number) => void

/** Interactive questions an engine may need answered (implemented by the UI bridge). */
export interface Prompter {
  /** Resolves with the answer type for the request kind (see `PromptAnswer`); null when dismissed. */
  ask(request: PromptRequest): Promise<unknown>
}

type PromptAnswer<K extends PromptRequest['kind']> = K extends 'hostKey' | 'certificate'
  ? TrustAnswer
  : K extends 'confirm'
    ? boolean
    : K extends 'chmod'
      ? ChmodAnswer | null
      : K extends 'overwrite'
        ? OverwriteAnswer | null
        : string | null

export function ask<R extends PromptRequest>(prompter: Prompter, request: R): Promise<PromptAnswer<R['kind']>> {
  return prompter.ask(request) as Promise<PromptAnswer<R['kind']>>
}

export interface SessionOptions {
  connectTimeout: number
  keepAlive: boolean
  /** Bytes per second, 0 = unlimited. */
  downloadLimit: number
  uploadLimit: number
  /** "Explicit TLS if available" may not fall back to plain FTP (TLS already worked for this server). */
  requireTLS?: boolean
}

export interface RemoteStat {
  size: number | null
  modified: number | null
}

/** One connection to one server. */
export interface RemoteSession {
  readonly site: Site
  readonly secure: boolean
  connect(): Promise<void>
  close(): void
  readonly closed: boolean
  onClose?: () => void
  pwd(): Promise<string>
  list(path: string): Promise<FileEntry[]>
  stat(path: string): Promise<RemoteStat | null>
  mkdir(path: string): Promise<void>
  rename(from: string, to: string): Promise<void>
  deleteFile(path: string): Promise<void>
  removeDirectory(path: string): Promise<void>
  chmod(path: string, mode: number): Promise<void>
  rawCommand(command: string): Promise<string>
  download(remote: string, local: string, offset: number, signal: AbortSignal, progress: ProgressHandler): Promise<void>
  upload(local: string, remote: string, offset: number, signal: AbortSignal, progress: ProgressHandler): Promise<void>
}

export interface SessionContext {
  site: Site
  password: string
  options: SessionOptions
  prompter: Prompter
  log: LogSink
  /** Called when the user chose to always trust a site's invalid TLS certificate. */
  trustCertificate(site: Site): void
  hostKeys: {
    check(host: string, port: number, key: string): 'trusted' | 'unknown' | 'changed'
    trust(host: string, port: number, key: string): void
  }
  /** Accepted FTPS certificates (see CertificateStore). */
  certificates: {
    hasPin(host: string, port: number): boolean
    check(host: string, port: number, fingerprint: string, usePin: boolean): 'trusted' | 'unknown' | 'changed'
    trust(host: string, port: number, fingerprint: string, persist: boolean): void
  }
}

/** Token-bucket style limiter: delays chunks so the average rate stays under `bytesPerSecond`. */
export class Throttle extends Transform {
  private readonly started = Date.now()
  private total = 0

  constructor(private readonly bytesPerSecond: number) {
    super()
  }

  override _transform(chunk: Buffer, _enc: BufferEncoding, done: TransformCallback): void {
    this.total += chunk.length
    const wait = (this.total / this.bytesPerSecond) * 1000 - (Date.now() - this.started)
    if (wait > 5) setTimeout(() => done(null, chunk), wait)
    else done(null, chunk)
  }
}

/** Serialises async operations (basic-ftp allows only one command at a time per connection). */
export class Mutex {
  private tail: Promise<unknown> = Promise.resolve()

  run<T>(task: () => Promise<T>): Promise<T> {
    const result = this.tail.then(task, task)
    this.tail = result.catch(() => undefined)
    return result
  }
}

export function expandHome(p: string, home: string): string {
  return p === '~' || p.startsWith('~/') || p.startsWith('~\\') ? home + p.slice(1) : p
}

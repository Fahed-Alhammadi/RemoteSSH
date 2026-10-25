import { Transform, type TransformCallback } from 'node:stream'
import type { ChmodAnswer, FileEntry, LogKind, OverwriteAnswer, PromptRequest, Site, TrustAnswer } from '../../shared/types'

export class SessionError extends Error {}
export class CancelledError extends SessionError {
  constructor() {
    super('Interrupted by user')
  }
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

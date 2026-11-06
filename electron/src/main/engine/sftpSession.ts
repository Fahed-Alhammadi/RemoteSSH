import fs from 'node:fs'
import os from 'node:os'
import { pipeline } from 'node:stream/promises'
import { Client, utils, type ClientChannel, type ConnectConfig, type FileEntryWithStats, type SFTPWrapper, type Stats } from 'ssh2'
import { effectivePort, effectiveUser } from '../../shared/site'
import type { FileEntry, Site } from '../../shared/types'
import { Permissions, RemotePath } from '../../shared/util'
import { describeHostKey } from '../store/knownHosts'
import {
  ask,
  CancelledError,
  expandHome,
  PermanentError,
  sessionError,
  SessionError,
  Throttle,
  type ProgressHandler,
  type RemoteSession,
  type RemoteStat,
  type SessionContext,
} from './session'

/**
 * A keyboard-interactive prompt that asks for the account password ("Password:", "user@host's password:"),
 * not a one-time password or verification code; only those get the saved password.
 */
export function isPasswordPrompt(prompt: string): boolean {
  return /^\s*(?:\S+'s\s+)?password\s*:?\s*$/i.test(prompt)
}

const S_IFMT = 0o170000
const S_IFDIR = 0o040000
const S_IFLNK = 0o120000

/** SFTP over ssh2: password, keyboard-interactive or key-file login, with host-key verification. */
export class SFTPSession implements RemoteSession {
  readonly site: Site
  readonly secure = true
  closed = false
  onClose?: () => void
  private readonly client = new Client()
  private sftp: SFTPWrapper | null = null

  constructor(private readonly ctx: SessionContext) {
    this.site = ctx.site
  }

  async connect(): Promise<void> {
    const { site, options, log } = this.ctx
    const port = effectivePort(site)
    // ssh2's own readyTimeout keeps running while the user reads a host key or types a one-time code,
    // so it is off and this timer is paused while a question is open.
    let timer: NodeJS.Timeout | null = null
    let onTimeout = () => undefined as void
    const pause = () => {
      if (timer) clearTimeout(timer)
      timer = null
    }
    const arm = () => {
      pause()
      if (options.connectTimeout > 0) timer = setTimeout(() => onTimeout(), options.connectTimeout * 1000)
    }
    const config: ConnectConfig = {
      host: site.host,
      port,
      username: effectiveUser(site),
      readyTimeout: 0,
      keepaliveInterval: options.keepAlive ? 30_000 : 0,
      tryKeyboard: site.logonType !== 'keyFile',
      hostVerifier: (key: Buffer, verify: (ok: boolean) => void) => {
        pause()
        this.verifyHostKey(key)
          .then(verify, () => verify(false))
          .finally(arm)
      },
    }
    if (site.logonType === 'keyFile') {
      Object.assign(config, await this.loadKey())
    } else {
      config.password = this.ctx.password
    }

    await new Promise<void>((resolve, reject) => {
      let settled = false
      const fail = (e: Error) => {
        if (settled) return
        settled = true
        pause()
        this.closed = true
        this.client.end() // e.g. the SFTP subsystem failed after login: don't leave the socket open
        reject(e)
      }
      onTimeout = () => {
        if (settled) return
        fail(new SessionError('Timed out while connecting.'))
        this.client.destroy()
      }
      // The saved password answers one hidden "Password" prompt; anything else (one-time codes,
      // a second factor, a repeated password prompt after a wrong one) is asked of the user.
      let passwordUsed = false
      this.client.on('keyboard-interactive', (_name, instructions, _lang, prompts, finish) => {
        void (async () => {
          const answers: string[] = []
          for (const { prompt, echo } of prompts) {
            if (!echo && !passwordUsed && this.ctx.password && isPasswordPrompt(prompt)) {
              passwordUsed = true
              answers.push(this.ctx.password)
              continue
            }
            const title = `${effectiveUser(site)}@${site.host}`
            const message = [instructions, prompt].filter(Boolean).join('\n')
            pause()
            const answer = echo
              ? await ask(this.ctx.prompter, { kind: 'text', title, message, initial: '' })
              : await ask(this.ctx.prompter, { kind: 'password', title, message })
            if (answer == null) return fail(new CancelledError('Login cancelled.'))
            arm()
            answers.push(answer)
          }
          finish(answers)
        })().catch((e: Error) => fail(e))
      })
      this.client.once('ready', () => {
        this.client.sftp((err, sftp) => {
          if (err) return fail(new SessionError(err.message))
          if (settled) return
          settled = true
          pause()
          this.sftp = sftp
          resolve()
        })
      })
      this.client.on('error', (err: Error & { level?: string }) => {
        if (err.level === 'client-authentication') fail(new PermanentError(`Authentication failed: ${err.message}`))
        // A rejected host key is the user's decision: CancelledError keeps the queue from asking again.
        else if (this.hostKeyRejected) fail(new CancelledError("The server's host key was rejected."))
        else fail(new SessionError(err.message))
      })
      this.client.on('close', () => {
        fail(this.hostKeyRejected ? new CancelledError("The server's host key was rejected.") : new SessionError('Connection closed.'))
        this.markClosed()
      })
      arm()
      this.client.connect(config)
    })
    log('status', `Connected to ${site.host}`)
  }

  private hostKeyRejected = false

  private async verifyHostKey(blob: Buffer): Promise<boolean> {
    const { site, hostKeys, prompter, log } = this.ctx
    const port = effectivePort(site)
    const key = describeHostKey(blob)
    const status = hostKeys.check(site.host, port, key.line)
    if (status === 'trusted') return true
    const answer = await ask(prompter, {
      kind: 'hostKey',
      host: site.host,
      port,
      keyType: key.type,
      fingerprint: key.fingerprint,
      changed: status === 'changed',
    })
    if (answer === 'reject') {
      this.hostKeyRejected = true
      log('error', `Host key ${key.fingerprint} rejected`)
      return false
    }
    if (answer === 'always') hostKeys.trust(site.host, port, key.line)
    return true
  }

  /** Reads the key file; asks for a passphrase only when the key is encrypted. */
  private async loadKey(): Promise<Pick<ConnectConfig, 'privateKey' | 'passphrase'>> {
    const path = expandHome(this.site.keyFilePath, os.homedir())
    if (!path) throw new SessionError('No key file is set for this site.')
    let privateKey: Buffer
    try {
      privateKey = fs.readFileSync(path)
    } catch (e) {
      throw new SessionError(`Could not read key file: ${(e as Error).message}`)
    }
    const parsed = utils.parseKey(privateKey)
    if (!(parsed instanceof Error)) return { privateKey }
    if (!/passphrase/i.test(parsed.message)) throw new SessionError(`Unsupported key file: ${parsed.message}`)
    for (let attempt = 0; attempt < 3; attempt++) {
      const passphrase = await ask(this.ctx.prompter, {
        kind: 'password',
        title: 'Key passphrase',
        message: `Enter the passphrase for ${path.split(/[\\/]/).pop()}:`,
      })
      if (passphrase == null) throw new CancelledError()
      if (!(utils.parseKey(privateKey, passphrase) instanceof Error)) return { privateKey, passphrase }
      this.ctx.log('error', 'Wrong passphrase.')
    }
    throw new SessionError('Wrong passphrase.')
  }

  close(): void {
    this.client.end()
    this.markClosed()
  }

  private markClosed(): void {
    if (this.closed && !this.sftp) return
    this.closed = true
    this.sftp = null
    this.onClose?.()
  }

  private get channel(): SFTPWrapper {
    if (!this.sftp || this.closed) throw new SessionError('Not connected.')
    return this.sftp
  }

  private call<T>(fn: (sftp: SFTPWrapper, cb: (err: Error | null | undefined, value?: T) => void) => void): Promise<T> {
    return new Promise((resolve, reject) => {
      try {
        fn(this.channel, (err, value) => (err ? reject(sessionError(err)) : resolve(value as T)))
      } catch (e) {
        reject(e)
      }
    })
  }

  pwd(): Promise<string> {
    return this.call<string>((s, cb) => s.realpath('.', cb))
  }

  async list(path: string): Promise<FileEntry[]> {
    const items = await this.call<FileEntryWithStats[]>((s, cb) => s.readdir(path, cb))
    const entries = await Promise.all(
      items.filter((i) => i.filename !== '.' && i.filename !== '..').map((i) => this.toEntry(path, i)),
    )
    this.ctx.log('status', `Directory listing of "${path}" successful`)
    return entries
  }

  private async toEntry(dir: string, item: FileEntryWithStats): Promise<FileEntry> {
    const mode = item.attrs.mode ?? 0
    const isLink = (mode & S_IFMT) === S_IFLNK
    let isDirectory = (mode & S_IFMT) === S_IFDIR
    if (isLink) {
      // Follow links so linked directories can be opened.
      try {
        const target = await this.call<Stats>((s, cb) => s.stat(RemotePath.join(dir, item.filename), cb))
        isDirectory = target.isDirectory()
      } catch {
        // Dangling link: show it as a file.
      }
    }
    const tokens = item.longname.split(/\s+/)
    return {
      name: item.filename,
      isDirectory,
      isLink,
      size: isDirectory ? null : (item.attrs.size ?? null),
      modified: item.attrs.mtime ? item.attrs.mtime * 1000 : null,
      permissions: mode ? Permissions.symbolic(mode) : '',
      owner: tokens.length > 3 ? tokens[2] : String(item.attrs.uid ?? ''),
      group: tokens.length > 3 ? tokens[3] : String(item.attrs.gid ?? ''),
    }
  }

  async stat(path: string): Promise<RemoteStat | null> {
    try {
      const st = await this.call<Stats>((s, cb) => s.stat(path, cb))
      return { size: st.size, modified: st.mtime ? st.mtime * 1000 : null }
    } catch (e) {
      if (/no such file|not found/i.test((e as Error).message)) return null
      throw e
    }
  }

  mkdir(path: string): Promise<void> {
    return this.call((s, cb) => s.mkdir(path, cb))
  }

  rename(from: string, to: string): Promise<void> {
    return this.call((s, cb) => s.rename(from, to, cb))
  }

  deleteFile(path: string): Promise<void> {
    return this.call((s, cb) => s.unlink(path, cb))
  }

  removeDirectory(path: string): Promise<void> {
    return this.call((s, cb) => s.rmdir(path, cb))
  }

  chmod(path: string, mode: number): Promise<void> {
    return this.call((s, cb) => s.chmod(path, mode, cb))
  }

  async rawCommand(): Promise<string> {
    throw new SessionError('Custom commands are only supported with FTP.')
  }

  /** Interactive login shell on a PTY, for the terminal. */
  shell(cols: number, rows: number): Promise<ClientChannel> {
    return new Promise((resolve, reject) => {
      this.client.shell({ term: 'xterm-256color', cols, rows }, (err, channel) =>
        err ? reject(new SessionError(`Could not start a shell: ${err.message}`)) : resolve(channel),
      )
    })
  }

  async download(remote: string, local: string, offset: number, signal: AbortSignal, progress: ProgressHandler): Promise<void> {
    const limit = this.ctx.options.downloadLimit
    if (offset === 0 && limit === 0) {
      // fastGet keeps many reads in flight, which is much faster on high-latency links.
      return this.cancellable(signal, (cb) =>
        this.channel.fastGet(remote, local, { step: (done) => progress(done) }, cb),
      )
    }
    const source = this.channel.createReadStream(remote, { start: offset })
    let done = offset
    source.on('data', (chunk: Buffer) => progress((done += chunk.length)))
    const target = fs.createWriteStream(local, { flags: offset > 0 ? 'r+' : 'w', start: offset })
    await this.piped(signal, limit > 0 ? [source, new Throttle(limit), target] : [source, target])
  }

  async upload(local: string, remote: string, offset: number, signal: AbortSignal, progress: ProgressHandler): Promise<void> {
    const limit = this.ctx.options.uploadLimit
    if (offset === 0 && limit === 0) {
      return this.cancellable(signal, (cb) =>
        this.channel.fastPut(local, remote, { step: (done) => progress(done) }, cb),
      )
    }
    const source = fs.createReadStream(local, { start: offset })
    let done = offset
    source.on('data', (chunk) => progress((done += chunk.length)))
    const target = this.channel.createWriteStream(remote, { flags: offset > 0 ? 'r+' : 'w', start: offset })
    await this.piped(signal, limit > 0 ? [source, new Throttle(limit), target] : [source, target])
  }

  /** fastGet/fastPut cannot be aborted, so cancelling drops this (pooled) connection. */
  private cancellable(signal: AbortSignal, start: (cb: (err?: Error | null) => void) => void): Promise<void> {
    return new Promise((resolve, reject) => {
      if (signal.aborted) return reject(new CancelledError())
      const abort = () => {
        this.close()
        reject(new CancelledError())
      }
      signal.addEventListener('abort', abort, { once: true })
      try {
        start((err) => {
          signal.removeEventListener('abort', abort)
          if (signal.aborted) return
          if (err) reject(sessionError(err))
          else resolve()
        })
      } catch (e) {
        signal.removeEventListener('abort', abort)
        reject(e)
      }
    })
  }

  private async piped(signal: AbortSignal, streams: [NodeJS.ReadableStream, ...NodeJS.WritableStream[]]): Promise<void> {
    try {
      await (pipeline as (...args: unknown[]) => Promise<void>)(...streams, { signal })
    } catch (e) {
      if (signal.aborted) throw new CancelledError()
      throw sessionError(e)
    }
  }
}

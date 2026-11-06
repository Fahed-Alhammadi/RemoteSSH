import fs from 'node:fs'
import { isIP } from 'node:net'
import { pipeline as pipe, type Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { TLSSocket } from 'node:tls'
import { Client, FileType, FTPError, type FileInfo } from 'basic-ftp'
import { effectivePort, effectiveUser } from '../../shared/site'
import type { FileEntry, Site } from '../../shared/types'
import { Permissions } from '../../shared/util'
import {
  ask,
  CancelledError,
  Mutex,
  PermanentError,
  sessionError,
  SessionError,
  Throttle,
  type ProgressHandler,
  type RemoteSession,
  type RemoteStat,
  type SessionContext,
} from './session'

/** FTP / FTPS (explicit or implicit TLS) over basic-ftp. Passive mode only. */
export class FTPSession implements RemoteSession {
  readonly site: Site
  secure = false
  closed = false
  onClose?: () => void
  private readonly client: Client
  private readonly mutex = new Mutex()
  private keepAliveTimer: NodeJS.Timeout | null = null
  private lastActivity = Date.now()
  /** True while a keep-alive NOOP runs, so it stays out of the message log. */
  private keepingAlive = false

  constructor(private readonly ctx: SessionContext) {
    this.site = ctx.site
    this.client = new Client(ctx.options.connectTimeout * 1000)
    const ftp = this.client.ftp
    ftp.verbose = true
    ftp.log = (message: string) => {
      if (this.keepingAlive) return
      if (message.startsWith('> ')) ctx.log('command', message.slice(2))
      else if (message.startsWith('< ')) ctx.log('response', message.slice(2).trimEnd())
      else if (!message.startsWith('Trying ')) ctx.log('status', message)
    }
  }

  async connect(): Promise<void> {
    const { site, log } = this.ctx
    const host = site.host
    const port = effectivePort(site)
    if (site.transferMode === 'active') log('status', 'Active mode is not available in this version; using passive mode.')
    // Verification is done in verifyCertificate() so the user can be asked; SNI is only valid for names.
    const tls = { rejectUnauthorized: false, servername: isIP(host) ? undefined : host }
    try {
      if (site.encryption === 'requireImplicit') {
        await this.client.connectImplicitTLS(host, port, tls)
        await this.verifyCertificate()
      } else {
        await this.client.connect(host, port)
        if (site.encryption !== 'plain') {
          try {
            await this.client.useTLS(tls)
            await this.verifyCertificate()
          } catch (e) {
            if (site.encryption === 'requireExplicit' || !(e instanceof FTPError)) throw e
            if (this.ctx.options.requireTLS) {
              throw new SessionError('The server refused TLS although it used TLS before; not continuing unencrypted. Someone may be intercepting the connection.')
            }
            log('error', 'Server does not support FTP over TLS; continuing unencrypted. Your password is sent in plain text.')
          }
        }
      }
      this.secure = this.client.ftp.hasTLS
      await this.client.login(effectiveUser(site) || 'anonymous', site.logonType === 'anonymous' ? 'anonymous@' : this.ctx.password)
      await this.client.useDefaultSettings()
      this.client.ftp.socket.once('close', () => this.markClosed())
      if (this.ctx.options.keepAlive) this.startKeepAlive()
    } catch (e) {
      this.client.close()
      this.closed = true
      throw this.wrap(e)
    }
  }

  /**
   * Asks about certificates Node could not verify, before any credentials are sent. An accepted certificate
   * is pinned by fingerprint: a different one later (e.g. an attacker's) is asked about again, as "changed".
   */
  private async verifyCertificate(): Promise<void> {
    const socket = this.client.ftp.socket as TLSSocket
    const cert = socket.getPeerCertificate()
    const fingerprint = cert.fingerprint256 ?? ''
    this.pinDataCertificate(fingerprint)
    if (socket.authorized) return
    const { site, certificates, log } = this.ctx
    const port = effectivePort(site)
    let status = certificates.check(site.host, port, fingerprint, site.trustInvalidCertificate)
    if (status === 'unknown' && site.trustInvalidCertificate && fingerprint && !certificates.hasPin(site.host, port)) {
      // Older versions trusted any certificate for such a site; from now on only this one is.
      certificates.trust(site.host, port, fingerprint, true)
      log('status', `Pinned the trusted certificate for ${site.host}:${port} (${fingerprint}).`)
      status = 'trusted'
    }
    if (status === 'trusted') return
    const name = (o: Record<string, string | string[]> | undefined) =>
      o ? Object.entries(o).map(([k, v]) => `${k}=${Array.isArray(v) ? v.join(',') : v}`).join(', ') : ''
    const answer = await ask(this.ctx.prompter, {
      kind: 'certificate',
      host: site.host,
      port,
      subject: name(cert.subject as unknown as Record<string, string>),
      issuer: name(cert.issuer as unknown as Record<string, string>),
      validFrom: cert.valid_from ?? '',
      validTo: cert.valid_to ?? '',
      fingerprint,
      reason: String(socket.authorizationError ?? 'The certificate could not be verified.'),
      changed: status === 'changed',
    })
    if (answer === 'reject' || !fingerprint) throw new CancelledError('The server certificate was not trusted.')
    certificates.trust(site.host, port, fingerprint, answer === 'always')
    if (answer === 'always' && !site.trustInvalidCertificate) this.ctx.trustCertificate({ ...site, trustInvalidCertificate: true })
  }

  /**
   * basic-ftp opens data connections with the control connection's TLS options, where Node's checks
   * are off so verifyCertificate() can ask the user. Each data connection must instead present the
   * control connection's certificate (or resume its TLS session), so file contents can't be intercepted.
   */
  private pinDataCertificate(fingerprint: string | undefined): void {
    const ftp = this.client.ftp
    const accessor = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(ftp), 'dataSocket')
    if (!accessor?.get || !accessor.set) throw new SessionError('Cannot verify FTPS data connections with this basic-ftp version.')
    const { get, set } = accessor
    Object.defineProperty(ftp, 'dataSocket', {
      configurable: true,
      get() {
        return get.call(this)
      },
      set(socket: unknown) {
        if (socket instanceof TLSSocket) {
          socket.once('secureConnect', () => {
            if (socket.isSessionReused() || (fingerprint && socket.getPeerCertificate().fingerprint256 === fingerprint)) return
            socket.destroy(new Error('The data connection presented a different certificate than the server; transfer stopped.'))
          })
        }
        set.call(this, socket)
      },
    })
  }

  /** Sends NOOP after 30 s without a command, so servers and NAT routers don't drop an idle connection. */
  private startKeepAlive(): void {
    this.keepAliveTimer = setInterval(() => {
      if (this.closed || Date.now() - this.lastActivity < 30_000) return
      void this.mutex
        .run(async () => {
          if (this.closed) return
          this.keepingAlive = true
          try {
            await this.client.send('NOOP')
          } finally {
            this.keepingAlive = false
            this.lastActivity = Date.now()
          }
        })
        .catch(() => undefined) // a dead connection is reported by the socket's 'close'
    }, 10_000)
    this.keepAliveTimer.unref()
  }

  close(): void {
    this.client.close()
    this.markClosed()
  }

  private markClosed(): void {
    if (this.keepAliveTimer) clearInterval(this.keepAliveTimer)
    this.keepAliveTimer = null
    if (this.closed) return
    this.closed = true
    this.onClose?.()
  }

  private wrap(e: unknown): Error {
    if (e instanceof SessionError) return e
    // 5xx replies are permanent (550 permission denied, 553 bad name, 530 login incorrect); 4xx are temporary.
    if (e instanceof FTPError) return e.code >= 500 ? new PermanentError(`${e.code} ${e.message}`) : new SessionError(`${e.code} ${e.message}`)
    const message = e instanceof Error ? e.message : String(e)
    if (this.closed && /closed|ECONNRESET|aborted/i.test(message)) return new SessionError('Connection closed.')
    return sessionError(e)
  }

  private run<T>(task: () => Promise<T>): Promise<T> {
    return this.mutex.run(async () => {
      if (this.closed) throw new SessionError('Not connected.')
      try {
        return await task()
      } catch (e) {
        throw this.wrap(e)
      } finally {
        this.lastActivity = Date.now()
      }
    })
  }

  pwd(): Promise<string> {
    return this.run(() => this.client.pwd())
  }

  list(path: string): Promise<FileEntry[]> {
    return this.run(async () => {
      const items = await this.client.list(path)
      this.ctx.log('status', `Directory listing of "${path}" successful`)
      return items.filter((i) => i.name !== '.' && i.name !== '..').map(toEntry)
    })
  }

  stat(path: string): Promise<RemoteStat | null> {
    return this.run(async () => {
      let size: number
      try {
        size = await this.client.size(path)
      } catch (e) {
        if (e instanceof FTPError && e.code >= 500) return null
        throw e
      }
      let modified: number | null = null
      try {
        modified = (await this.client.lastMod(path)).getTime()
      } catch {
        // MDTM is optional.
      }
      return { size, modified }
    })
  }

  mkdir(path: string): Promise<void> {
    return this.run(async () => void (await this.client.send(`MKD ${path}`)))
  }

  rename(from: string, to: string): Promise<void> {
    return this.run(async () => void (await this.client.rename(from, to)))
  }

  deleteFile(path: string): Promise<void> {
    return this.run(async () => void (await this.client.send(`DELE ${path}`)))
  }

  removeDirectory(path: string): Promise<void> {
    return this.run(async () => void (await this.client.send(`RMD ${path}`)))
  }

  chmod(path: string, mode: number): Promise<void> {
    return this.run(async () => void (await this.client.send(`SITE CHMOD ${Permissions.octal(mode)} ${path}`)))
  }

  rawCommand(command: string): Promise<string> {
    return this.run(async () => {
      const res = await this.client.sendIgnoringError(command)
      return `${res.code} ${res.message}`
    })
  }

  download(remote: string, local: string, offset: number, signal: AbortSignal, progress: ProgressHandler): Promise<void> {
    return this.transfer(signal, progress, offset, async () => {
      const limit = this.ctx.options.downloadLimit
      if (limit > 0) {
        const throttle = new Throttle(limit)
        const written = pipeline(throttle, fs.createWriteStream(local, { flags: offset > 0 ? 'r+' : 'w', start: offset }))
        // Wait for both, so a local write error (disk full) is neither an unhandled rejection nor lets the
        // next command start while basic-ftp is still busy; the write error is the more useful one.
        const [download, write] = await Promise.allSettled([this.client.downloadTo(throttle, remote, offset), written])
        if (write.status === 'rejected') throw write.reason
        if (download.status === 'rejected') throw download.reason
      } else {
        await this.client.downloadTo(local, remote, offset)
      }
    })
  }

  upload(local: string, remote: string, offset: number, signal: AbortSignal, progress: ProgressHandler): Promise<void> {
    return this.transfer(signal, progress, offset, async () => {
      const file = fs.createReadStream(local, { start: offset })
      const limit = this.ctx.options.uploadLimit
      // pipeline (not pipe) forwards a read error (file deleted, no access) to the throttle, which basic-ftp
      // listens to, and closes the file when the upload fails; with pipe() the error event had no listener.
      const source: Readable = limit > 0 ? pipe(file, new Throttle(limit), () => undefined) : file
      try {
        if (offset > 0) await this.client.appendFrom(source, remote)
        else await this.client.uploadFrom(source, remote)
      } finally {
        // basic-ftp only consumes (and closes) the source once the server accepted STOR; a refusal
        // (553, quota, PASV failure) would otherwise leak the open file.
        file.destroy()
        if (source !== file) source.destroy()
      }
    })
  }

  private transfer(signal: AbortSignal, progress: ProgressHandler, offset: number, body: () => Promise<void>): Promise<void> {
    return this.run(async () => {
      if (signal.aborted) throw new CancelledError()
      const abort = () => this.close()
      signal.addEventListener('abort', abort, { once: true })
      this.client.trackProgress((info) => progress(offset + info.bytes))
      try {
        await body()
      } catch (e) {
        if (signal.aborted) throw new CancelledError()
        throw e
      } finally {
        this.client.trackProgress()
        signal.removeEventListener('abort', abort)
      }
    })
  }
}

const months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec']

/** Parses LIST dates basic-ftp leaves raw: "Jan 05 12:30", "Jan 05 2024" or DOS "01-05-24 12:30PM". */
export function parseListDate(raw: string, now = new Date()): number | null {
  const unix = /^([A-Za-z]{3})\s+(\d{1,2})\s+(?:(\d{1,2}):(\d{2})|(\d{4}))$/.exec(raw.trim())
  if (unix) {
    const month = months.indexOf(unix[1].toLowerCase())
    if (month < 0) return null
    const day = Number(unix[2])
    if (unix[5]) return Date.UTC(Number(unix[5]), month, day)
    let year = now.getUTCFullYear()
    const candidate = Date.UTC(year, month, day, Number(unix[3]), Number(unix[4]))
    // Without a year the date is within the last six months; a future date means last year.
    if (candidate > now.getTime() + 86_400_000) year -= 1
    return Date.UTC(year, month, day, Number(unix[3]), Number(unix[4]))
  }
  const dos = /^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})\s*([AP]M)?$/i.exec(raw.trim())
  if (dos) {
    let year = Number(dos[3])
    if (year < 100) year += year < 70 ? 2000 : 1900
    let hour = Number(dos[4])
    const ampm = dos[6]?.toUpperCase()
    if (ampm === 'PM' && hour < 12) hour += 12
    if (ampm === 'AM' && hour === 12) hour = 0
    return Date.UTC(year, Number(dos[1]) - 1, Number(dos[2]), hour, Number(dos[5]))
  }
  return null
}

function toEntry(info: FileInfo): FileEntry {
  let permissions = ''
  if (info.permissions) {
    const p = info.permissions
    const type = info.type === FileType.Directory ? 'd' : info.type === FileType.SymbolicLink ? 'l' : '-'
    permissions = Permissions.symbolic((p.user << 6) | (p.group << 3) | p.world).replace(/^./, type)
  }
  return {
    name: info.name,
    isDirectory: info.type === FileType.Directory,
    isLink: info.type === FileType.SymbolicLink,
    size: info.type === FileType.Directory ? null : info.size,
    modified: info.modifiedAt ? info.modifiedAt.getTime() : parseListDate(info.rawModifiedAt),
    permissions,
    owner: info.user ?? '',
    group: info.group ?? '',
  }
}

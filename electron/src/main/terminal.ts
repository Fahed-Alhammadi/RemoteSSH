import type { ClientChannel } from 'ssh2'
import { Events, type TerminalEvent } from '../shared/api'
import type { Site } from '../shared/types'
import { hasControlChars, shellQuote } from '../shared/util'
import type { SFTPSession } from './engine/sftpSession'

interface TerminalDeps {
  /** A new, connected SSH session for the site (never the browse session). */
  connect(site: Site): Promise<SFTPSession>
  send(channel: string, payload: TerminalEvent[]): void
  error(text: string): void
}

interface Shell {
  session: SFTPSession
  channel: ClientChannel
  output: string
  exitCode: number | null
  /** Characters sent to the renderer that xterm has not drawn yet. */
  unacked: number
  paused: boolean
}

/** Flow control: reading from the server pauses while this much output waits to be drawn, and resumes below LOW. */
const HIGH_WATER = 1_000_000
const LOW_WATER = 200_000

/**
 * Interactive SSH shells for the terminal panel, one connection each. Output is batched every 16 ms, and the
 * SSH channel is paused while the renderer is behind (e.g. `cat` of a huge log), so memory stays bounded.
 */
export class Terminals {
  private shells = new Map<number, Shell>()
  private nextID = 0
  private flushTimer: NodeJS.Timeout | null = null
  private ended: TerminalEvent[] = []

  constructor(private readonly deps: TerminalDeps) {}

  /** Opens a shell; when `dir` is not the login directory the shell changes to it first. */
  async open(site: Site, cols: number, rows: number, dir: string | null): Promise<number> {
    const session = await this.deps.connect(site)
    try {
      const home = await session.pwd()
      const channel = await session.shell(cols, rows)
      const id = ++this.nextID
      const shell: Shell = { session, channel, output: '', exitCode: null, unacked: 0, paused: false }
      this.shells.set(id, shell)
      const append = (text: string) => {
        shell.output += text
        shell.unacked += text.length
        if (!shell.paused && shell.unacked > HIGH_WATER) {
          shell.paused = true
          channel.pause()
        }
        this.flushTimer ??= setTimeout(() => this.flush(), 16)
      }
      channel.setEncoding('utf8')
      channel.stderr.setEncoding('utf8')
      channel.on('data', append)
      channel.stderr.on('data', append)
      // Without a listener a stream error (e.g. a write racing the remote close) would crash the main process;
      // the 'close' handler below reports the end either way.
      channel.on('error', () => undefined)
      channel.on('exit', (code: number | null) => {
        shell.exitCode = code
      })
      channel.on('close', () => {
        if (!this.shells.has(id)) return
        this.shells.delete(id)
        session.close()
        this.ended.push({ id, data: shell.output, ended: shell.exitCode ? `exit ${shell.exitCode}` : 'closed' })
        shell.output = ''
        this.flush()
      })
      // The leading space keeps the command out of shell history (HISTCONTROL=ignorespace).
      if (dir && dir !== home) {
        if (hasControlChars(dir)) this.deps.error('The folder name contains control characters; the terminal opened in your home folder.')
        else channel.write(` cd -- ${shellQuote(dir)} && clear\n`)
      }
      return id
    } catch (e) {
      session.close()
      throw e
    }
  }

  write(id: number, data: string): void {
    const channel = this.shells.get(id)?.channel
    if (channel?.writable) channel.write(data)
  }

  ack(id: number, chars: number): void {
    const shell = this.shells.get(id)
    if (!shell) return
    shell.unacked = Math.max(0, shell.unacked - chars)
    if (shell.paused && shell.unacked < LOW_WATER) {
      shell.paused = false
      shell.channel.resume()
    }
  }

  resize(id: number, cols: number, rows: number): void {
    this.shells.get(id)?.channel.setWindow(rows, cols, 0, 0)
  }

  close(id: number): void {
    const shell = this.shells.get(id)
    if (!shell) return
    this.shells.delete(id)
    shell.channel.close()
    shell.session.close()
  }

  closeAll(): void {
    for (const id of [...this.shells.keys()]) this.close(id)
  }

  private flush(): void {
    if (this.flushTimer) clearTimeout(this.flushTimer)
    this.flushTimer = null
    const events: TerminalEvent[] = []
    for (const [id, shell] of this.shells) {
      if (!shell.output) continue
      events.push({ id, data: shell.output })
      shell.output = ''
    }
    events.push(...this.ended)
    this.ended = []
    if (events.length) this.deps.send(Events.terminal, events)
  }
}

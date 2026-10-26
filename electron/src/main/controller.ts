import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { dialog, shell, type BrowserWindow } from 'electron'
import type { ConnectResult, InvokeMethod, QueueUpdate } from '../shared/api'
import { Events } from '../shared/api'
import { displayAddress, effectivePort, effectiveUser, InputError, parseQuickConnect } from '../shared/site'
import type {
  AppSettings,
  ConnectionInfo,
  FileEntry,
  LogKind,
  LogLine,
  PromptRequest,
  RemoteListing,
  Site,
  SitesState,
  SitesUpdate,
  TransferItem,
} from '../shared/types'
import { errorMessage, Permissions, RemotePath } from '../shared/util'
import { FTPSession } from './engine/ftpSession'
import { listLocal, localStat } from './engine/localFS'
import { ask, SessionError, type Prompter, type RemoteSession, type SessionContext } from './engine/session'
import { SFTPSession } from './engine/sftpSession'
import { KnownHostsStore } from './store/knownHosts'
import { ARCHIVE_EXTENSION, decodeArchive, encodeArchive } from './store/siteArchive'
import { SiteStore, type SecretCipher } from './store/siteStore'
import { QueueStore, SettingsStore } from './store/settingsStore'
import { Terminals } from './terminal'
import { TransferManager } from './transfers'

type Handler = (...args: never[]) => unknown

/** Main-process application state: sites, the browsing connection, transfers and UI prompts. */
export class Controller implements Prompter {
  private readonly sites: SiteStore
  private readonly settingsStore: SettingsStore
  private readonly knownHosts: KnownHostsStore
  readonly transfers: TransferManager
  private session: RemoteSession | null = null
  private site: Site | null = null
  /** Quickconnect sites (not in the site manager) and passwords entered this run. */
  private transientSites = new Map<string, Site>()
  private sessionPasswords = new Map<string, string>()
  private pendingPrompts = new Map<number, (value: unknown) => void>()
  private promptID = 0
  private logBuffer: LogLine[] = []
  private logTimer: NodeJS.Timeout | null = null
  private logID = 0
  private edits = new EditWatcher(this)
  private terminals = new Terminals({
    connect: async (site) => {
      const s = this.makeSession(site, await this.passwordFor(site), true)
      if (!(s instanceof SFTPSession)) throw new SessionError('The terminal needs an SFTP (SSH) site.')
      await s.connect()
      return s
    },
    send: (channel, payload) => this.send(channel, payload),
  })

  constructor(
    dataDir: string,
    cipher: SecretCipher,
    private readonly window: () => BrowserWindow | null,
  ) {
    this.sites = new SiteStore(dataDir, cipher)
    this.settingsStore = new SettingsStore(dataDir)
    this.knownHosts = new KnownHostsStore(dataDir)
    this.transfers = new TransferManager(
      {
        settings: () => this.settingsStore.value,
        site: (id) => this.findSite(id),
        connectSession: async (site) => {
          const s = this.makeSession(site, await this.passwordFor(site), true)
          await s.connect()
          return s
        },
        browseSession: (siteID) => (this.site?.id === siteID && this.session && !this.session.closed ? this.session : null),
        prompter: this,
        status: (t) => this.log('status', t),
        error: (t) => this.log('error', t),
        publish: (u) => this.send(Events.queue, u),
        transferFinished: (item) => this.transferFinished(item),
      },
      new QueueStore(dataDir),
    )
  }

  get settings(): AppSettings {
    return this.settingsStore.value
  }

  /** IPC handlers by method name. */
  handlers(): Record<InvokeMethod, Handler> {
    return {
      homeDir: () => os.homedir(),
      getSites: () => this.sites.state(),
      saveSites: (u: SitesUpdate) => this.saveSites(u),
      importSites: () => this.importSites(),
      exportSites: () => this.exportSites(),
      getSettings: () => this.settingsStore.value,
      saveSettings: (s: AppSettings) => {
        this.settingsStore.save(s)
        this.transfers.resume()
      },
      chooseKeyFile: () => this.choose('openFile', 'Choose key file', path.join(os.homedir(), '.ssh')),
      chooseFolder: () => this.choose('openDirectory', 'Choose folder', os.homedir()),
      connect: (id: string) => this.connectTo(id),
      quickConnect: (host: string, user: string, password: string, port: string) => this.quickConnect(host, user, password, port),
      reconnect: () => this.reconnect(),
      disconnect: () => this.disconnect(),
      listRemote: (p: string) => this.listRemote(p),
      remoteMkdir: (dir: string, name: string) => this.remote((s) => s.mkdir(RemotePath.join(dir, name))),
      remoteRename: (dir: string, from: string, to: string) =>
        this.remote((s) => s.rename(RemotePath.join(dir, from), RemotePath.join(dir, to))),
      remoteDelete: (dir: string, entries: FileEntry[]) => this.remoteDelete(dir, entries),
      remoteChmod: (dir: string, entries: FileEntry[]) => this.remoteChmod(dir, entries),
      rawCommand: (cmd: string) => this.remote((s) => s.rawCommand(cmd)),
      viewEdit: (dir: string, entry: FileEntry) => this.viewEdit(dir, entry),
      listLocal: (p: string) => listLocal(p),
      localMkdir: (dir: string, name: string) => fs.promises.mkdir(path.join(dir, name)),
      localRename: (dir: string, from: string, to: string) => fs.promises.rename(path.join(dir, from), path.join(dir, to)),
      localTrash: async (dir: string, names: string[]) => {
        for (const n of names) await shell.trashItem(path.join(dir, n))
      },
      localOpen: async (dir: string, names: string[]) => {
        for (const n of names) await shell.openPath(path.join(dir, n))
      },
      localReveal: (dir: string, names: string[]) => shell.showItemInFolder(names.length ? path.join(dir, names[0]) : dir),
      download: (entries: FileEntry[], remoteDir: string, localDir: string) =>
        this.transfers.enqueueDownload(entries, remoteDir, localDir, this.requireSite()),
      upload: (paths: string[], remoteDir: string) => this.transfers.enqueueUpload(paths, remoteDir, this.requireSite()),
      queueSnapshot: (): QueueUpdate => ({ upserts: this.transfers.all(), removed: [], processing: this.transfers.processing }),
      setProcessing: (on: boolean) => this.transfers.setProcessing(on),
      stopAll: () => this.transfers.stopAll(),
      removeTransfers: (ids: string[]) => this.transfers.remove(ids),
      retryTransfers: (ids: string[]) => this.transfers.retry(ids),
      clearFinished: () => this.transfers.clearFinished(),
      terminalOpen: (cols: number, rows: number, dir: string | null) => this.openTerminal(cols, rows, dir),
      terminalInput: (id: number, data: string) => this.terminals.write(id, data),
      terminalResize: (id: number, cols: number, rows: number) => this.terminals.resize(id, cols, rows),
      terminalClose: (id: number) => this.terminals.close(id),
      answerPrompt: (id: number, value: unknown) => {
        this.pendingPrompts.get(id)?.(value)
        this.pendingPrompts.delete(id)
      },
    }
  }

  // MARK: Plumbing

  send(channel: string, payload: unknown): void {
    const win = this.window()
    if (win && !win.isDestroyed()) win.webContents.send(channel, payload)
  }

  log(kind: LogKind, text: string): void {
    this.logBuffer.push({ id: ++this.logID, time: Date.now(), kind, text })
    if (!this.logTimer) {
      this.logTimer = setTimeout(() => {
        this.logTimer = null
        this.send(Events.log, this.logBuffer)
        this.logBuffer = []
      }, 50)
    }
  }

  /** Prompter: shows a dialog in the renderer and waits for the answer. */
  ask(request: PromptRequest): Promise<unknown> {
    const win = this.window()
    if (!win || win.isDestroyed()) return Promise.resolve(request.kind === 'confirm' ? false : request.kind === 'hostKey' || request.kind === 'certificate' ? 'reject' : null)
    const id = ++this.promptID
    return new Promise((resolve) => {
      this.pendingPrompts.set(id, resolve)
      this.send(Events.prompt, { id, request })
    })
  }

  private async choose(kind: 'openFile' | 'openDirectory', title: string, defaultPath: string): Promise<string | null> {
    const win = this.window()
    const options = { title, defaultPath, properties: [kind, 'showHiddenFiles'] as ('openFile' | 'openDirectory' | 'showHiddenFiles')[] }
    const result = win ? await dialog.showOpenDialog(win, options) : await dialog.showOpenDialog(options)
    return result.canceled ? null : (result.filePaths[0] ?? null)
  }

  // MARK: Sites

  private findSite(id: string): Site | null {
    return this.transientSites.get(id) ?? this.sites.load().find((s) => s.id === id) ?? null
  }

  private requireSite(): Site {
    if (!this.site || !this.session || this.session.closed) throw new SessionError('Not connected.')
    return this.site
  }

  private saveSites(update: SitesUpdate): SitesState {
    this.sites.save(update)
    for (const id of Object.keys(update.passwords)) this.sessionPasswords.delete(id)
    this.transfers.closeIdle()
    return this.sites.state()
  }

  private async importSites(): Promise<SitesState | null> {
    const win = this.window()
    const options: Electron.OpenDialogOptions = {
      title: 'Import from RemoteSSH',
      filters: [{ name: 'RemoteSSH sites', extensions: [ARCHIVE_EXTENSION, 'json'] }],
      properties: ['openFile'],
    }
    const result = win ? await dialog.showOpenDialog(win, options) : await dialog.showOpenDialog(options)
    if (result.canceled || !result.filePaths[0]) return null
    const { sites, passwords } = decodeArchive(await fs.promises.readFile(result.filePaths[0], 'utf8'))
    const state = this.sites.state()
    this.sites.save({ sites: [...state.sites, ...sites], passwords })
    const stored = Object.keys(passwords).length
    this.log('status', `Imported ${sites.length} site${sites.length === 1 ? '' : 's'}${stored && !state.canStorePasswords ? ' (passwords not saved: no secure storage available)' : ''}.`)
    return this.sites.state()
  }

  private async exportSites(): Promise<void> {
    const win = this.window()
    const state = this.sites.state()
    if (!state.sites.length) throw new InputError('There are no sites to export.')
    let includePasswords = false
    if (state.withPassword.length) {
      const opts: Electron.MessageBoxOptions = {
        type: 'question',
        message: 'Include saved passwords?',
        detail: 'Passwords are stored in the export file as plain text. Anyone with the file can read them.',
        buttons: ['Export Without Passwords', 'Include Passwords', 'Cancel'],
        defaultId: 0,
        cancelId: 2,
      }
      const answer = win ? await dialog.showMessageBox(win, opts) : await dialog.showMessageBox(opts)
      if (answer.response === 2) return
      includePasswords = answer.response === 1
    }
    const saveOpts: Electron.SaveDialogOptions = {
      title: 'Export Sites',
      defaultPath: path.join(os.homedir(), `RemoteSSH Sites.${ARCHIVE_EXTENSION}`),
      filters: [{ name: 'RemoteSSH sites', extensions: [ARCHIVE_EXTENSION] }],
    }
    const result = win ? await dialog.showSaveDialog(win, saveOpts) : await dialog.showSaveDialog(saveOpts)
    if (result.canceled || !result.filePath) return
    let passwords: Record<string, string> | undefined
    if (includePasswords) {
      passwords = {}
      for (const id of state.withPassword) {
        const pw = this.sites.password(id)
        if (pw) passwords[id] = pw
      }
    }
    await fs.promises.writeFile(result.filePath, encodeArchive(state.sites, passwords), { mode: 0o600 })
    this.log('status', `Exported ${state.sites.length} sites to ${result.filePath}`)
  }

  private trustCertificate(site: Site): void {
    if (this.transientSites.has(site.id)) this.transientSites.set(site.id, site)
    else {
      this.sites.update(site)
      this.send(Events.sites, this.sites.state())
    }
    if (this.site?.id === site.id) this.site = site
  }

  // MARK: Connection

  private async passwordFor(site: Site): Promise<string> {
    if (site.logonType === 'anonymous' || site.logonType === 'keyFile') return ''
    const cached = this.sessionPasswords.get(site.id)
    if (cached != null) return cached
    if (site.logonType === 'normal') {
      const stored = this.sites.password(site.id)
      if (stored != null) return stored
      // Without an OS keyring nothing was saved, so ask instead of sending an empty password.
      if (this.transientSites.has(site.id) || this.sites.state().canStorePasswords) return ''
    }
    const pw = await ask(this, { kind: 'password', title: 'Enter password', message: `Password for ${displayAddress(site)}:` })
    if (pw == null) throw new SessionError('Connection cancelled.')
    this.sessionPasswords.set(site.id, pw)
    return pw
  }

  private makeSession(site: Site, password: string, quiet = false): RemoteSession {
    const s = this.settingsStore.value
    const ctx: SessionContext = {
      site,
      password,
      options: {
        connectTimeout: s.connectTimeout,
        keepAlive: s.keepAlive,
        downloadLimit: s.downloadLimitKiB * 1024,
        uploadLimit: s.uploadLimitKiB * 1024,
      },
      prompter: this,
      // Transfer connections only report errors, so the log stays readable.
      log: quiet ? (kind, text) => kind === 'error' && this.log(kind, text) : (kind, text) => this.log(kind, text),
      trustCertificate: (updated) => this.trustCertificate(updated),
      hostKeys: this.knownHosts,
    }
    return site.serverProtocol === 'sftp' ? new SFTPSession(ctx) : new FTPSession(ctx)
  }

  private connectionInfo(): ConnectionInfo {
    if (!this.session || !this.site) return { state: 'disconnected', site: null, secure: false }
    return { state: this.session.closed ? 'disconnected' : 'connected', site: this.site, secure: this.session.secure }
  }

  private async open(site: Site, password: string | null, initialPath: string | null): Promise<ConnectResult> {
    this.disconnect()
    this.site = site
    this.send(Events.connection, { state: 'connecting', site, secure: false } satisfies ConnectionInfo)
    try {
      const pw = password ?? (await this.passwordFor(site))
      const session = this.makeSession(site, pw)
      this.session = session
      session.onClose = () => {
        if (this.session !== session) return
        this.log('error', 'Connection closed by server')
        this.send(Events.connection, this.connectionInfo())
      }
      await session.connect()
      if (this.session !== session) throw new SessionError('Connection cancelled.')
      if (password != null && site.logonType !== 'anonymous') this.sessionPasswords.set(site.id, password)
      let remote: RemoteListing | null = null
      const start = initialPath || site.defaultRemoteDirectory
      try {
        remote = await this.listRemote(start || (await session.pwd()))
      } catch (e) {
        if (!start) throw e
        this.log('error', `${start}: ${errorMessage(e)}`)
        remote = await this.listRemote(await session.pwd())
      }
      const local = site.defaultLocalDirectory && localStat(site.defaultLocalDirectory)?.isDirectory ? site.defaultLocalDirectory : null
      this.send(Events.connection, this.connectionInfo())
      return { connection: this.connectionInfo(), remote, localPath: local }
    } catch (e) {
      this.log('error', errorMessage(e))
      this.session?.close()
      this.session = null
      this.send(Events.connection, this.connectionInfo())
      throw e
    }
  }

  private connectTo(id: string): Promise<ConnectResult> {
    const site = this.findSite(id)
    if (!site) throw new InputError('Site not found.')
    if (!site.host) throw new InputError('This site has no host name.')
    this.log('status', `Connecting to ${site.host}:${effectivePort(site)}...`)
    return this.open(site, null, null)
  }

  private quickConnect(host: string, user: string, password: string, port: string): Promise<ConnectResult> {
    const input = parseQuickConnect(host, user, password, port)
    // Reuse the id of an identical earlier quickconnect so queued transfers keep working.
    const existing = [...this.transientSites.values()].find((s) => displayAddress(s) === displayAddress(input.site))
    if (existing) input.site.id = existing.id
    this.transientSites.set(input.site.id, input.site)
    this.log('status', `Connecting to ${input.site.host}:${effectivePort(input.site)}...`)
    return this.open(input.site, input.site.logonType === 'anonymous' ? '' : input.password, input.initialPath)
  }

  private reconnect(): Promise<ConnectResult> {
    if (!this.site) throw new InputError('There is no previous connection.')
    const site = this.findSite(this.site.id) ?? this.site
    return this.open(site, this.sessionPasswords.get(site.id) ?? null, null)
  }

  disconnect(): void {
    const s = this.session
    this.session = null
    if (s) {
      s.close()
      this.log('status', 'Disconnected from server')
    }
    this.send(Events.connection, this.connectionInfo())
  }

  // MARK: Remote operations

  private async remote<T>(op: (s: RemoteSession) => Promise<T>): Promise<T> {
    if (!this.session || this.session.closed) throw new SessionError('Not connected.')
    try {
      return await op(this.session)
    } catch (e) {
      this.log('error', errorMessage(e))
      throw e
    }
  }

  private async listRemote(p: string): Promise<RemoteListing> {
    const target = RemotePath.normalize(p)
    const entries = await this.remote((s) => s.list(target))
    return { path: target, entries }
  }

  private async remoteDelete(dir: string, entries: FileEntry[]): Promise<void> {
    await this.remote(async (s) => {
      const removeTree = async (target: string): Promise<void> => {
        for (const child of await s.list(target)) {
          const p = RemotePath.join(target, child.name)
          if (child.isDirectory && !child.isLink) await removeTree(p)
          else await s.deleteFile(p)
        }
        await s.removeDirectory(target)
      }
      for (const e of entries) {
        const p = RemotePath.join(dir, e.name)
        if (e.isDirectory && !e.isLink) await removeTree(p)
        else await s.deleteFile(p)
        this.log('status', `Deleted ${p}`)
      }
    })
  }

  private async remoteChmod(dir: string, entries: FileEntry[]): Promise<void> {
    const first = entries[0]
    if (!first) return
    const answer = await ask(this, {
      kind: 'chmod',
      names: entries.map((e) => e.name),
      mode: entries.length === 1 ? Permissions.bits(first.permissions) : null,
    })
    if (!answer) return
    await this.remote(async (s) => {
      const apply = async (p: string, isDir: boolean): Promise<void> => {
        await s.chmod(p, answer.mode)
        if (isDir && answer.recursive) {
          for (const c of await s.list(p)) await apply(RemotePath.join(p, c.name), c.isDirectory && !c.isLink)
        }
      }
      for (const e of entries) await apply(RemotePath.join(dir, e.name), e.isDirectory)
    })
  }

  private async viewEdit(dir: string, entry: FileEntry): Promise<void> {
    const site = this.requireSite()
    const remotePath = RemotePath.join(dir, entry.name)
    const tmpDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'remotessh-edit-'))
    const local = path.join(tmpDir, entry.name)
    await this.remote((s) => s.download(remotePath, local, 0, new AbortController().signal, () => undefined))
    this.edits.watch(local, remotePath, site.id)
    const error = await shell.openPath(local)
    if (error) throw new SessionError(error)
  }

  editedFileChanged(local: string, remote: string, siteID: string): void {
    const site = this.findSite(siteID)
    if (site) this.transfers.enqueueEditedUpload(local, remote, site)
  }

  private async openTerminal(cols: number, rows: number, dir: string | null): Promise<number> {
    const site = this.requireSite()
    if (site.serverProtocol !== 'sftp') throw new SessionError('The terminal needs an SFTP (SSH) site.')
    try {
      const id = await this.terminals.open(site, cols, rows, dir)
      this.log('status', `Terminal opened: ${effectiveUser(site)}@${site.host}`)
      return id
    } catch (e) {
      this.log('error', `Terminal: ${errorMessage(e)}`)
      throw e
    }
  }

  private transferFinished(item: TransferItem): void {
    if (item.direction === 'download') this.send(Events.refresh, ['local', path.dirname(item.localPath)])
    else this.send(Events.refresh, ['remote', RemotePath.parent(item.remotePath)])
  }

  shutdown(): void {
    this.transfers.persist()
    this.transfers.closeIdle()
    this.session?.close()
    this.terminals.closeAll()
    this.edits.stop()
  }

  showWindow(): BrowserWindow | null {
    return this.window()
  }
}

/** Watches files opened with View/Edit and offers to upload them after they are saved. */
class EditWatcher {
  private files: { local: string; remote: string; siteID: string; modified: number }[] = []
  private timer: NodeJS.Timeout | null = null
  private asking = false

  constructor(private readonly controller: Controller) {}

  watch(local: string, remote: string, siteID: string): void {
    this.files.push({ local, remote, siteID, modified: localStat(local)?.modified ?? 0 })
    this.timer ??= setInterval(() => void this.poll(), 2000)
  }

  private async poll(): Promise<void> {
    if (this.asking) return
    this.files = this.files.filter((f) => fs.existsSync(f.local))
    if (!this.files.length) return this.stop()
    for (const f of this.files) {
      const now = localStat(f.local)?.modified
      if (now == null || now === f.modified) continue
      f.modified = now
      this.asking = true
      const win = this.controller.showWindow()
      const opts: Electron.MessageBoxOptions = {
        type: 'question',
        message: `${path.basename(f.local)} has changed`,
        detail: `Upload it back to ${f.remote}?`,
        buttons: ['Upload', "Don't Upload"],
        defaultId: 0,
        cancelId: 1,
      }
      const answer = win ? await dialog.showMessageBox(win, opts) : await dialog.showMessageBox(opts)
      this.asking = false
      if (answer.response === 0) this.controller.editedFileChanged(f.local, f.remote, f.siteID)
    }
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  }
}

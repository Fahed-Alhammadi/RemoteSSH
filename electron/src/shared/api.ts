import type {
  AppSettings,
  ConnectionInfo,
  FileEntry,
  LocalListing,
  LogLine,
  MenuAction,
  PromptEnvelope,
  RemoteListing,
  SitesState,
  SitesUpdate,
  TransferItem,
} from './types'

export interface ConnectResult {
  connection: ConnectionInfo
  remote: RemoteListing | null
  /** Site's default local directory, when set and present. */
  localPath: string | null
}

export interface QueueUpdate {
  upserts: TransferItem[]
  removed: string[]
  processing: boolean
}

/** The API the preload script exposes to the renderer as `window.remotessh`. */
export interface RemoteSSHApi {
  platform: string
  homeDir(): Promise<string>

  // Sites and settings
  getSites(): Promise<SitesState>
  saveSites(update: SitesUpdate): Promise<SitesState>
  importSites(): Promise<SitesState | null>
  exportSites(): Promise<void>
  getSettings(): Promise<AppSettings>
  saveSettings(settings: AppSettings): Promise<void>
  chooseKeyFile(): Promise<string | null>
  chooseFolder(): Promise<string | null>

  // Connection
  connect(siteID: string): Promise<ConnectResult>
  quickConnect(host: string, user: string, password: string, port: string): Promise<ConnectResult>
  reconnect(): Promise<ConnectResult>
  disconnect(): Promise<void>

  // Remote
  listRemote(path: string): Promise<RemoteListing>
  remoteMkdir(dir: string, name: string): Promise<void>
  remoteRename(dir: string, from: string, to: string): Promise<void>
  remoteDelete(dir: string, entries: FileEntry[]): Promise<void>
  remoteChmod(dir: string, entries: FileEntry[]): Promise<void>
  rawCommand(command: string): Promise<string>
  viewEdit(dir: string, entry: FileEntry): Promise<void>

  // Local
  listLocal(path: string): Promise<LocalListing>
  localMkdir(dir: string, name: string): Promise<void>
  localRename(dir: string, from: string, to: string): Promise<void>
  localTrash(dir: string, names: string[]): Promise<void>
  localOpen(dir: string, names: string[]): Promise<void>
  localReveal(dir: string, names: string[]): Promise<void>
  pathForFile(file: File): string

  // Transfers
  download(entries: FileEntry[], remoteDir: string, localDir: string): Promise<void>
  upload(localPaths: string[], remoteDir: string): Promise<void>
  queueSnapshot(): Promise<QueueUpdate>
  setProcessing(on: boolean): Promise<void>
  stopAll(): Promise<void>
  removeTransfers(ids: string[]): Promise<void>
  retryTransfers(ids: string[]): Promise<void>
  clearFinished(): Promise<void>

  // Prompts
  answerPrompt(id: number, value: unknown): Promise<void>

  // Events (each returns an unsubscribe function)
  onLog(cb: (lines: LogLine[]) => void): () => void
  onQueue(cb: (update: QueueUpdate) => void): () => void
  onPrompt(cb: (prompt: PromptEnvelope) => void): () => void
  onConnection(cb: (info: ConnectionInfo) => void): () => void
  onMenu(cb: (action: MenuAction) => void): () => void
  onSitesChanged(cb: (state: SitesState) => void): () => void
  onRefresh(cb: (pane: 'local' | 'remote', dir: string) => void): () => void
}

/** IPC channel names; invoke channels mirror the API method names. */
export const Events = {
  log: 'event:log',
  queue: 'event:queue',
  prompt: 'event:prompt',
  connection: 'event:connection',
  menu: 'event:menu',
  sites: 'event:sites',
  refresh: 'event:refresh',
} as const

export const invokeMethods = [
  'homeDir', 'getSites', 'saveSites', 'importSites', 'exportSites', 'getSettings', 'saveSettings',
  'chooseKeyFile', 'chooseFolder', 'connect', 'quickConnect', 'reconnect', 'disconnect',
  'listRemote', 'remoteMkdir', 'remoteRename', 'remoteDelete', 'remoteChmod', 'rawCommand', 'viewEdit',
  'listLocal', 'localMkdir', 'localRename', 'localTrash', 'localOpen', 'localReveal',
  'download', 'upload', 'queueSnapshot', 'setProcessing', 'stopAll', 'removeTransfers', 'retryTransfers',
  'clearFinished', 'answerPrompt',
] as const satisfies readonly (keyof RemoteSSHApi)[]

export type InvokeMethod = (typeof invokeMethods)[number]

// Data model shared by the main process and the renderer. Field names and enum values match the
// macOS app's Codable types, so `.remotessh` files move freely between platforms.

export type ServerProtocol = 'ftp' | 'sftp'
export type FTPEncryption = 'explicitIfAvailable' | 'requireExplicit' | 'requireImplicit' | 'plain'
export type LogonType = 'anonymous' | 'normal' | 'askForPassword' | 'keyFile'
export type TransferMode = 'passive' | 'active'

export interface Site {
  id: string
  name: string
  /** Slash-separated folder in the site manager tree ("" = top level). */
  folder: string
  host: string
  port: number
  serverProtocol: ServerProtocol
  encryption: FTPEncryption
  logonType: LogonType
  user: string
  keyFilePath: string
  transferMode: TransferMode
  defaultLocalDirectory: string
  defaultRemoteDirectory: string
  comments: string
  /** Set after the user accepted an untrusted TLS certificate for this site. */
  trustInvalidCertificate: boolean
}

export interface FileEntry {
  name: string
  isDirectory: boolean
  isLink: boolean
  size: number | null
  /** Milliseconds since the epoch. */
  modified: number | null
  /** Symbolic ("drwxr-xr-x") or octal ("0755") permissions; "" when unknown. */
  permissions: string
  owner: string
  group: string
}

export type OverwriteAction =
  | 'ask' | 'overwrite' | 'overwriteIfNewer' | 'overwriteIfDifferentSize' | 'resume' | 'rename' | 'skip'

export interface AppSettings {
  maxConcurrentTransfers: number
  defaultOverwriteDownload: OverwriteAction
  defaultOverwriteUpload: OverwriteAction
  showHiddenFiles: boolean
  /** KiB/s, 0 = unlimited. */
  downloadLimitKiB: number
  uploadLimitKiB: number
  connectTimeout: number
  keepAlive: boolean
  retryCount: number
  showDirectoryComparison: boolean
  checkForUpdates: boolean
}

export const defaultSettings: AppSettings = {
  maxConcurrentTransfers: 2,
  defaultOverwriteDownload: 'ask',
  defaultOverwriteUpload: 'ask',
  showHiddenFiles: true,
  downloadLimitKiB: 0,
  uploadLimitKiB: 0,
  connectTimeout: 20,
  keepAlive: true,
  retryCount: 2,
  showDirectoryComparison: true,
  checkForUpdates: true,
}

export type TransferDirection = 'download' | 'upload'
export type TransferStatus = 'queued' | 'transferring' | 'finished' | 'failed'

export interface TransferItem {
  id: string
  siteID: string
  direction: TransferDirection
  localPath: string
  remotePath: string
  size: number | null
  status: TransferStatus
  transferred: number
  error?: string
  finishedAt?: number
  /** Bytes per second while transferring. */
  speed?: number
}

export type LogKind = 'status' | 'command' | 'response' | 'error' | 'listing'
export interface LogLine {
  id: number
  time: number
  kind: LogKind
  text: string
}

export type ConnectionState = 'disconnected' | 'connecting' | 'connected'

export interface ConnectionInfo {
  state: ConnectionState
  site: Site | null
  /** True when the control connection is encrypted (SFTP, or FTP with TLS). */
  secure: boolean
}

export interface LocalListing {
  path: string
  /** null at the file-system root (or the drive list on Windows). */
  parent: string | null
  entries: FileEntry[]
}

export interface RemoteListing {
  path: string
  entries: FileEntry[]
}

/** Site manager save payload: a password of `null` clears it, a missing key leaves it unchanged. */
export interface SitesUpdate {
  sites: Site[]
  passwords: Record<string, string | null>
}

export interface SitesState {
  sites: Site[]
  /** Site ids that have a stored password. */
  withPassword: string[]
  /** False when the OS offers no secure storage; passwords are then never saved. */
  canStorePasswords: boolean
}

// Questions the main process asks the user (see `Prompter`).
export type PromptRequest =
  | { kind: 'text'; title: string; message: string; initial: string }
  | { kind: 'password'; title: string; message: string }
  | { kind: 'confirm'; title: string; message: string; confirm: string; destructive?: boolean }
  | { kind: 'hostKey'; host: string; port: number; keyType: string; fingerprint: string; changed: boolean }
  | {
      kind: 'certificate'
      host: string
      port: number
      subject: string
      issuer: string
      validFrom: string
      validTo: string
      fingerprint: string
      reason: string
    }
  | {
      kind: 'overwrite'
      direction: TransferDirection
      source: string
      target: string
      sourceSize: number | null
      targetSize: number | null
      sourceModified: number | null
      targetModified: number | null
    }
  | { kind: 'chmod'; names: string[]; mode: number | null }

export type TrustAnswer = 'once' | 'always' | 'reject'
export interface OverwriteAnswer {
  action: Exclude<OverwriteAction, 'ask'>
  applyToAll: boolean
  newName?: string
}
export interface ChmodAnswer {
  mode: number
  recursive: boolean
}

export interface PromptEnvelope {
  id: number
  request: PromptRequest
}

/** Menu and shortcut actions forwarded from the main process to the renderer. */
export type MenuAction =
  | 'siteManager' | 'importSites' | 'exportSites' | 'settings'
  | 'reconnect' | 'disconnect' | 'refresh' | 'customCommand'
  | 'toggleQueue' | 'clearFinished' | 'stopAll'
  | 'toggleHidden' | 'toggleCompare' | 'toggleSync' | 'toggleLog' | 'about'

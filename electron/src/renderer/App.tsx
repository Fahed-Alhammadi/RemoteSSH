import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  ArrowLeftRight,
  ChevronDown,
  CircleStop,
  Columns2,
  Copy,
  Download,
  Eye,
  EyeOff,
  FilePen,
  FolderOpen,
  FolderPlus,
  FolderSync,
  Globe,
  HardDrive,
  KeyRound,
  Laptop,
  Maximize2,
  Minimize2,
  Pause,
  Pencil,
  Play,
  Plug,
  PlugZap,
  RefreshCw,
  RotateCw,
  ScrollText,
  Server,
  Settings,
  ShieldCheck,
  ShieldOff,
  SquareTerminal,
  Trash2,
  Unplug,
  Upload,
  User,
  X,
} from 'lucide-react'
import type { ConnectResult } from '../shared/api'
import { displayAddress, effectivePort, effectiveUser } from '../shared/site'
import type {
  AppSettings,
  ConnectionInfo,
  FileEntry,
  LocalListing,
  LogLine,
  MenuAction,
  PromptRequest,
  RemoteListing,
  SitesState,
  TransferItem,
} from '../shared/types'
import { errorMessage, formatSize, RemotePath } from '../shared/util'
import { version } from '../../package.json'
import { api } from './api'
import { FilePane, type CompareMark, type DragPayload } from './components/FilePane'
import { LogView, QueueView } from './components/LogQueue'
import { PromptDialog } from './components/Prompts'
import { SettingsDialog } from './components/SettingsDialog'
import { SiteManager, siteIcon } from './components/SiteManager'
import type { TerminalRequest, TerminalStatus } from './components/TerminalView'
import { ContextMenu, IconButton, Modal, type MenuEntry } from './components/ui'

interface PendingPrompt {
  key: number
  request: PromptRequest
  resolve: (value: unknown) => void
}

const MAX_LOG = 5000
let promptKey = 0
const sep = api.platform === 'win32' ? '\\' : '/'
const joinLocal = (dir: string, name: string) => (dir === '' ? name : dir.endsWith(sep) ? dir + name : dir + sep + name)
const mod = api.platform === 'darwin' ? '⌘' : 'Ctrl+'
// xterm is large, so it loads with the first terminal.
const TerminalView = lazy(() => import('./components/TerminalView').then((m) => ({ default: m.TerminalView })))

export function App() {
  const [sites, setSites] = useState<SitesState>({ sites: [], withPassword: [], canStorePasswords: true })
  const [settings, setSettings] = useState<AppSettings | null>(null)
  const [conn, setConn] = useState<ConnectionInfo>({ state: 'disconnected', site: null, secure: false })
  const [local, setLocal] = useState<LocalListing | null>(null)
  const [remote, setRemote] = useState<RemoteListing | null>(null)
  const [remoteLoading, setRemoteLoading] = useState(false)
  const [localSel, setLocalSel] = useState<Set<string>>(new Set())
  const [remoteSel, setRemoteSel] = useState<Set<string>>(new Set())
  const [log, setLog] = useState<LogLine[]>([])
  const [queue, setQueue] = useState<Map<string, TransferItem>>(new Map())
  const [processing, setProcessing] = useState(true)
  const [prompts, setPrompts] = useState<PendingPrompt[]>([])
  const [dialog, setDialog] = useState<'sites' | 'settings' | 'about' | null>(null)
  const [compare, setCompare] = useState(true)
  const [syncBase, setSyncBase] = useState<{ local: string; remote: string } | null>(null)
  const [showLog, setShowLog] = useState(true)
  const [quick, setQuick] = useState({ host: '', user: '', password: '', port: '' })
  const [siteMenu, setSiteMenu] = useState<{ x: number; y: number } | null>(null)
  const [terminal, setTerminal] = useState<(TerminalRequest & { label: string }) | null>(null)
  const [terminalStatus, setTerminalStatus] = useState<TerminalStatus>('disconnected')
  const [terminalActive, setTerminalActive] = useState(false)
  const [terminalMax, setTerminalMax] = useState(false)
  const localLogID = useRef(0)

  const connected = conn.state === 'connected'
  const canTerminal = connected && conn.site?.serverProtocol === 'sftp'

  // MARK: Messages and prompts

  const addLog = useCallback((kind: LogLine['kind'], text: string) => {
    setLog((l) => [...l, { id: -++localLogID.current, time: Date.now(), kind, text }].slice(-MAX_LOG))
  }, [])
  const fail = useCallback((e: unknown) => addLog('error', errorMessage(e)), [addLog])

  const ask = useCallback(
    <T,>(request: PromptRequest) => new Promise<T>((resolve) => setPrompts((p) => [...p, { key: ++promptKey, request, resolve: resolve as (v: unknown) => void }])),
    [],
  )

  // MARK: Startup and events

  const navigateLocal = useCallback(async (path: string) => {
    try {
      const listing = await api.listLocal(path)
      setLocal(listing)
      setLocalSel(new Set())
      return listing
    } catch (e) {
      fail(e)
      return null
    }
  }, [fail])

  useEffect(() => {
    void api.getSites().then(setSites)
    void api.getSettings().then((s) => {
      setSettings(s)
      setCompare(s.showDirectoryComparison)
    })
    void api.homeDir().then(navigateLocal)
    void api.queueSnapshot().then((u) => {
      setQueue(new Map(u.upserts.map((i) => [i.id, i])))
      setProcessing(u.processing)
    })
    const offs = [
      api.onLog((lines) => setLog((l) => (l.length + lines.length > MAX_LOG ? [...l, ...lines].slice(-MAX_LOG) : [...l, ...lines]))),
      api.onQueue((u) => {
        setProcessing(u.processing)
        if (!u.upserts.length && !u.removed.length) return
        setQueue((q) => {
          const next = new Map(q)
          for (const id of u.removed) next.delete(id)
          for (const i of u.upserts) next.set(i.id, i)
          return next
        })
      }),
      api.onPrompt(({ id, request }) =>
        setPrompts((p) => [...p, { key: ++promptKey, request, resolve: (v) => void api.answerPrompt(id, v) }]),
      ),
      api.onConnection(setConn),
      api.onSitesChanged(setSites),
    ]
    return () => offs.forEach((off) => off())
  }, [navigateLocal])

  // MARK: Remote navigation

  const navigateRemote = useCallback(async (path: string, sync = true) => {
    setRemoteLoading(true)
    try {
      const listing = await api.listRemote(path)
      setRemote(listing)
      setRemoteSel(new Set())
      if (sync && syncBase && listing.path.startsWith(syncBase.remote)) {
        const rel = listing.path.slice(syncBase.remote.length).split('/').filter(Boolean)
        void navigateLocal(rel.reduce(joinLocal, syncBase.local))
      }
      return true
    } catch {
      return false
    } finally {
      setRemoteLoading(false)
    }
  }, [syncBase, navigateLocal])

  const goLocal = useCallback(async (path: string, sync = true) => {
    const listing = await navigateLocal(path)
    if (listing && sync && syncBase && connected && listing.path.startsWith(syncBase.local)) {
      const rel = listing.path.slice(syncBase.local.length).split(/[\\/]/).filter(Boolean)
      void navigateRemote(rel.reduce(RemotePath.join, syncBase.remote), false)
    }
  }, [navigateLocal, navigateRemote, syncBase, connected])

  const applyConnect = useCallback((result: ConnectResult) => {
    setConn(result.connection)
    setRemote(result.remote)
    setRemoteSel(new Set())
    setSyncBase(null)
    if (result.localPath) void navigateLocal(result.localPath)
  }, [navigateLocal])

  const connect = useCallback(async (run: () => Promise<ConnectResult>) => {
    setRemote(null)
    try {
      applyConnect(await run())
    } catch {
      // Already in the message log.
    }
  }, [applyConnect])

  // Refresh panes when transfers land in the visible folder.
  const latest = useRef({ local, remote, remoteLoading })
  latest.current = { local, remote, remoteLoading }
  useEffect(() => {
    const timers = new Map<string, number>()
    return api.onRefresh((pane, dir) => {
      const cur = latest.current
      const visible = pane === 'local' ? cur.local?.path === dir : cur.remote?.path === dir
      if (!visible || timers.has(pane)) return
      timers.set(pane, window.setTimeout(() => {
        timers.delete(pane)
        const now = latest.current
        if (pane === 'local' && now.local) {
          void api.listLocal(now.local.path).then(setLocal).catch(() => undefined)
        } else if (pane === 'remote' && now.remote && !now.remoteLoading) {
          void api.listRemote(now.remote.path).then(setRemote).catch(() => undefined)
        }
      }, 400))
    })
  }, [])

  // MARK: Actions

  const refreshLocal = () => local && void navigateLocal(local.path)
  const refreshRemote = () => remote && void navigateRemote(remote.path, false)

  const upload = (paths: string[], remoteDir = remote?.path) => {
    if (!connected || !remoteDir) return addLog('error', 'Connect to a server first.')
    api.upload(paths, remoteDir).catch(fail)
  }
  const download = (entries: FileEntry[], remoteDir = remote?.path, localDir = local?.path) => {
    if (!connected || !remoteDir || !localDir) return
    api.download(entries, remoteDir, localDir).catch(fail)
  }

  const openLocal = (entry: FileEntry) => {
    if (!local) return
    if (entry.isDirectory) void goLocal(joinLocal(local.path, entry.name))
    else if (connected) upload([joinLocal(local.path, entry.name)])
    else api.localOpen(local.path, [entry.name]).catch(fail)
  }

  const openRemote = async (entry: FileEntry) => {
    if (!remote) return
    const target = RemotePath.join(remote.path, entry.name)
    if (entry.isDirectory) void navigateRemote(target)
    else if (entry.isLink && (await navigateRemote(target))) return
    else download([entry])
  }

  const remoteDelete = async (entries: FileEntry[]) => {
    if (!remote || !entries.length) return
    const ok = await ask<boolean>({
      kind: 'confirm',
      title: 'Delete from server',
      message: entries.length === 1 ? `Really delete “${entries[0].name}” from the server?` : `Really delete ${entries.length} items from the server?`,
      confirm: 'Delete',
      destructive: true,
    })
    if (!ok) return
    await api.remoteDelete(remote.path, entries).catch(() => undefined)
    refreshRemote()
  }

  const localDelete = async (entries: FileEntry[]) => {
    if (!local || !entries.length) return
    const ok = await ask<boolean>({
      kind: 'confirm',
      title: 'Move to trash',
      message: entries.length === 1 ? `Move “${entries[0].name}” to the trash?` : `Move ${entries.length} items to the trash?`,
      confirm: 'Move to Trash',
      destructive: true,
    })
    if (!ok) return
    await api.localTrash(local.path, entries.map((e) => e.name)).catch(fail)
    refreshLocal()
  }

  const rename = async (side: 'local' | 'remote', entry: FileEntry) => {
    const dir = side === 'local' ? local?.path : remote?.path
    if (dir == null) return
    const name = await ask<string | null>({ kind: 'text', title: 'Rename', message: `New name for “${entry.name}”:`, initial: entry.name })
    if (!name || name === entry.name) return
    try {
      if (side === 'local') await api.localRename(dir, entry.name, name)
      else await api.remoteRename(dir, entry.name, name)
    } catch (e) {
      if (side === 'local') fail(e)
    }
    if (side === 'local') refreshLocal()
    else refreshRemote()
  }

  const mkdir = async (side: 'local' | 'remote') => {
    const dir = side === 'local' ? local?.path : remote?.path
    if (dir == null || dir === '') return
    const name = await ask<string | null>({ kind: 'text', title: 'Create directory', message: 'Name of the new directory:', initial: 'New directory' })
    if (!name) return
    try {
      if (side === 'local') await api.localMkdir(dir, name)
      else await api.remoteMkdir(dir, name)
    } catch (e) {
      if (side === 'local') fail(e)
      return
    }
    if (side === 'local') refreshLocal()
    else refreshRemote()
  }

  const customCommand = async () => {
    if (!connected) return
    const cmd = await ask<string | null>({ kind: 'text', title: 'Enter custom command', message: 'Command to send to the server (FTP only):', initial: '' })
    if (!cmd) return
    api.rawCommand(cmd).then((r) => addLog('response', r)).catch(() => undefined)
  }

  /** Shows the terminal; with `reuse`, a running shell changes to `dir` instead of a new one starting. */
  const openTerminal = (dir: string | null, reuse: boolean) => {
    if (!canTerminal || !conn.site) return addLog('error', 'The terminal needs a connection to an SFTP site.')
    const label = `${effectiveUser(conn.site)}@${conn.site.host}`
    // A running shell on another server is replaced rather than sent a cd.
    const same = reuse && terminal?.label === label && terminalStatus === 'connected'
    setTerminal((t) => ({ key: (t?.key ?? 0) + 1, dir, reuse: same, label }))
    setTerminalActive(true)
  }

  /** Shows the terminal tab, starting a shell when none is open and the site allows one. */
  const showTerminal = (show: boolean) => {
    if (show && !terminal && canTerminal) openTerminal(remote?.path ?? null, false)
    else setTerminalActive(show)
  }

  const toggleTerminal = () => showTerminal(!terminalActive)

  const closeTerminal = () => {
    setTerminal(null)
    setTerminalActive(false)
    setTerminalMax(false)
    setTerminalStatus('disconnected')
  }

  const toggleSync = () => {
    if (syncBase) setSyncBase(null)
    else if (connected && local && remote) setSyncBase({ local: local.path, remote: remote.path })
  }

  const runMenu = useRef<(a: MenuAction) => void>(() => undefined)
  runMenu.current = (action: MenuAction) => {
    switch (action) {
      case 'siteManager': return setDialog('sites')
      case 'settings': return setDialog('settings')
      case 'about': return setDialog('about')
      case 'importSites': return void api.importSites().then((s) => s && setSites(s)).catch(fail)
      case 'exportSites': return void api.exportSites().catch(fail)
      case 'reconnect': return void connect(() => api.reconnect())
      case 'disconnect': return void api.disconnect().then(() => (setRemote(null), setSyncBase(null)))
      case 'refresh': refreshLocal(); refreshRemote(); return
      case 'customCommand': return void customCommand()
      case 'toggleQueue': return void api.setProcessing(!processing)
      case 'stopAll': return void api.stopAll()
      case 'clearFinished': return void api.clearFinished()
      case 'toggleHidden':
        if (settings) {
          const next = { ...settings, showHiddenFiles: !settings.showHiddenFiles }
          setSettings(next)
          void api.saveSettings(next)
        }
        return
      case 'toggleCompare': return setCompare((c) => !c)
      case 'toggleSync': return toggleSync()
      case 'toggleLog': return setShowLog((s) => !s)
      case 'toggleTerminal': return toggleTerminal()
    }
  }
  useEffect(() => api.onMenu((a) => runMenu.current(a)), [])
  // Ctrl+` is also handled here: keys typed into the terminal do not always reach the native menu.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!e.ctrlKey || e.metaKey || e.altKey || e.code !== 'Backquote') return
      e.preventDefault()
      runMenu.current('toggleTerminal')
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  // MARK: Derived state

  const comparison = useMemo(() => {
    if (!compare || !connected || !local || !remote) return null
    const l = new Map<string, CompareMark>()
    const r = new Map<string, CompareMark>()
    const remoteByName = new Map(remote.entries.map((e) => [e.name, e]))
    const localNames = new Set<string>()
    for (const le of local.entries) {
      localNames.add(le.name)
      const re = remoteByName.get(le.name)
      if (!re) { l.set(le.name, 'lonely'); continue }
      if (le.isDirectory || re.isDirectory) continue
      if (le.size !== re.size) { l.set(le.name, 'different'); r.set(re.name, 'different'); continue }
      // FTP listings often have minute precision.
      if (le.modified != null && re.modified != null && Math.abs(le.modified - re.modified) > 60_000) {
        if (le.modified > re.modified) l.set(le.name, 'newer')
        else r.set(re.name, 'newer')
      }
    }
    for (const re of remote.entries) if (!localNames.has(re.name)) r.set(re.name, 'lonely')
    return { local: l, remote: r }
  }, [compare, connected, local, remote])

  const queueItems = useMemo(() => [...queue.values()], [queue])
  const queueStats = useMemo(() => {
    let pending = 0
    let bytes = 0
    for (const i of queueItems) {
      if (i.status === 'queued' || i.status === 'transferring') {
        pending++
        bytes += Math.max(0, (i.size ?? 0) - (i.status === 'transferring' ? i.transferred : 0))
      }
    }
    return { pending, bytes }
  }, [queueItems])

  const siteName = useCallback(
    (id: string) => sites.sites.find((s) => s.id === id)?.name ?? (conn.site?.id === id ? conn.site.host : 'Quickconnect'),
    [sites, conn.site],
  )

  // MARK: Menus

  const localMenu = (entries: FileEntry[]): MenuEntry[] => [
    { label: 'Upload', icon: Upload, disabled: !connected || !entries.length, onClick: () => local && upload(entries.map((e) => joinLocal(local.path, e.name))) },
    { label: 'Open', icon: FolderOpen, disabled: !entries.length, onClick: () => local && api.localOpen(local.path, entries.map((e) => e.name)).catch(fail) },
    { label: api.platform === 'win32' ? 'Show in Explorer' : 'Show in File Manager', icon: HardDrive, onClick: () => local && api.localReveal(local.path, entries.map((e) => e.name)) },
    'separator',
    { label: 'Create Directory…', icon: FolderPlus, disabled: local?.path === '', onClick: () => void mkdir('local') },
    { label: 'Rename…', icon: Pencil, disabled: entries.length !== 1, onClick: () => void rename('local', entries[0]) },
    { label: 'Move to Trash', icon: Trash2, danger: true, disabled: !entries.length, onClick: () => void localDelete(entries) },
    'separator',
    { label: 'Refresh', icon: RefreshCw, onClick: refreshLocal },
  ]

  const remoteMenu = (entries: FileEntry[]): MenuEntry[] => [
    { label: 'Download', icon: Download, disabled: !entries.length, onClick: () => download(entries) },
    { label: 'View / Edit', icon: FilePen, disabled: entries.length !== 1 || entries[0].isDirectory, onClick: () => remote && api.viewEdit(remote.path, entries[0]).catch(() => undefined) },
    'separator',
    { label: 'Create Directory…', icon: FolderPlus, onClick: () => void mkdir('remote') },
    { label: 'Rename…', icon: Pencil, disabled: entries.length !== 1, onClick: () => void rename('remote', entries[0]) },
    { label: 'Delete', icon: Trash2, danger: true, disabled: !entries.length, onClick: () => void remoteDelete(entries) },
    { label: 'File Permissions…', icon: KeyRound, disabled: !entries.length, onClick: () => remote && api.remoteChmod(remote.path, entries).then(refreshRemote).catch(() => undefined) },
    'separator',
    {
      label: 'Copy URL',
      icon: Copy,
      disabled: !conn.site,
      onClick: () => {
        if (!conn.site || !remote) return
        const base = displayAddress(conn.site)
        const urls = (entries.length ? entries.map((e) => RemotePath.join(remote.path, e.name)) : [remote.path]).map((p) => base + encodeURI(p))
        void navigator.clipboard.writeText(urls.join('\n'))
      },
    },
    {
      label: 'Open Terminal Here',
      icon: SquareTerminal,
      disabled: !canTerminal,
      onClick: () => {
        if (!remote) return
        const folder = entries.length === 1 && entries[0].isDirectory ? RemotePath.join(remote.path, entries[0].name) : remote.path
        openTerminal(folder, true)
      },
    },
    { label: 'Refresh', icon: RefreshCw, onClick: refreshRemote },
  ]

  const onDrop = (side: 'local' | 'remote') => (payload: DragPayload | { osPaths: string[] }, targetDir: string | null) => {
    if (side === 'remote' && remote) {
      const dir = targetDir ? RemotePath.join(remote.path, targetDir) : remote.path
      if ('osPaths' in payload) upload(payload.osPaths, dir)
      else upload(payload.entries.map((e) => joinLocal(payload.dir, e.name)), dir)
    } else if (side === 'local' && local && !('osPaths' in payload)) {
      download(payload.entries, payload.dir, targetDir ? joinLocal(local.path, targetDir) : local.path)
    }
  }

  // MARK: Render

  const prompt = prompts[0]
  const statusSite = conn.site

  return (
    <div className={`app${terminalActive && terminalMax ? ' terminal-max' : ''}`}>
      <header className="toolbar">
        <img className="brand" src="./icon.png" alt="" width={22} height={22} />
        <div className="group">
          <button type="button" className="toolbar-site" onClick={() => setDialog('sites')} title={`Site Manager (${mod}S)`}>
            <Server size={18} /> Sites
          </button>
          <button type="button" className="icon-button narrow" aria-label="Connect to a site" onClick={(e) => setSiteMenu({ x: e.currentTarget.getBoundingClientRect().left, y: e.currentTarget.getBoundingClientRect().bottom + 4 })}>
            <ChevronDown size={14} />
          </button>
        </div>
        <div className="group">
          <IconButton icon={RefreshCw} label="Refresh" shortcut="F5" onClick={() => runMenu.current('refresh')} />
          <IconButton icon={RotateCw} label="Reconnect" shortcut={`${mod}R`} disabled={!conn.site || conn.state === 'connecting'} onClick={() => runMenu.current('reconnect')} />
          <IconButton icon={Unplug} label="Disconnect" shortcut={`${mod}D`} disabled={conn.state === 'disconnected'} onClick={() => runMenu.current('disconnect')} />
        </div>
        <div className="group">
          <IconButton icon={processing ? Pause : Play} label={processing ? 'Pause queue' : 'Process queue'} shortcut={`${mod}P`} active={!processing} onClick={() => runMenu.current('toggleQueue')} />
          <IconButton icon={CircleStop} label="Stop all transfers" tint="var(--c-red)" disabled={!queueItems.some((i) => i.status === 'transferring')} onClick={() => runMenu.current('stopAll')} />
        </div>
        <div className="group">
          <IconButton icon={Columns2} label="Directory comparison" active={compare} onClick={() => setCompare((c) => !c)} />
          <IconButton icon={FolderSync} label="Synchronized browsing" active={!!syncBase} disabled={!connected} onClick={toggleSync} />
          <IconButton icon={settings?.showHiddenFiles ? Eye : EyeOff} label="Show hidden files" active={settings?.showHiddenFiles} onClick={() => runMenu.current('toggleHidden')} />
          <IconButton icon={ScrollText} label="Message log" active={showLog} onClick={() => setShowLog((s) => !s)} />
          <IconButton icon={SquareTerminal} label="Terminal" shortcut="Ctrl+`" active={terminalActive} onClick={toggleTerminal} />
        </div>
        <span className="spacer" />
        <IconButton icon={Settings} label="Settings" onClick={() => setDialog('settings')} />
      </header>

      <form
        className="quickconnect"
        onSubmit={(e) => {
          e.preventDefault()
          void connect(() => api.quickConnect(quick.host, quick.user, quick.password, quick.port))
        }}
      >
        <label><Globe size={14} /><input placeholder="Host (sftp://, ftp://, ftps://)" value={quick.host} spellCheck={false} onChange={(e) => setQuick({ ...quick, host: e.target.value })} /></label>
        <label><User size={14} /><input placeholder="Username" value={quick.user} spellCheck={false} onChange={(e) => setQuick({ ...quick, user: e.target.value })} /></label>
        <label><KeyRound size={14} /><input type="password" placeholder="Password" value={quick.password} onChange={(e) => setQuick({ ...quick, password: e.target.value })} /></label>
        <label className="port"><input placeholder="Port" value={quick.port} inputMode="numeric" onChange={(e) => setQuick({ ...quick, port: e.target.value.replace(/\D/g, '') })} /></label>
        <button type="submit" className="primary" disabled={!quick.host || conn.state === 'connecting'}>
          <PlugZap /> Connect
        </button>
      </form>

      {showLog && <LogView lines={log} />}

      <main className="panes">
        <FilePane
          side="local"
          title="Local"
          icon={Laptop}
          path={local?.path ?? ''}
          canGoUp={local?.parent != null}
          entries={local?.entries ?? []}
          showHidden={settings?.showHiddenFiles ?? true}
          comparison={comparison?.local ?? null}
          selection={localSel}
          onSelection={setLocalSel}
          onNavigate={(p) => void goLocal(p)}
          onUp={() => local?.parent != null && void goLocal(local.parent)}
          onRefresh={refreshLocal}
          onOpen={openLocal}
          onDrop={onDrop('local')}
          onDelete={(e) => void localDelete(e)}
          onRename={(e) => void rename('local', e)}
          menu={localMenu}
          pathForFile={api.pathForFile}
        />
        <FilePane
          side="remote"
          title="Remote"
          icon={Server}
          path={remote?.path ?? ''}
          canGoUp={!!remote && remote.path !== '/'}
          entries={remote?.entries ?? []}
          showHidden={settings?.showHiddenFiles ?? true}
          comparison={comparison?.remote ?? null}
          selection={remoteSel}
          onSelection={setRemoteSel}
          onNavigate={(p) => void navigateRemote(p)}
          onUp={() => remote && void navigateRemote(RemotePath.parent(remote.path))}
          onRefresh={refreshRemote}
          onOpen={(e) => void openRemote(e)}
          onDrop={onDrop('remote')}
          onDelete={(e) => void remoteDelete(e)}
          onRename={(e) => void rename('remote', e)}
          menu={remoteMenu}
          loading={remoteLoading}
          showOwner
          pathForFile={api.pathForFile}
          placeholder={
            connected && remote ? undefined : (
              <div className="unavailable">
                <div className="empty-icon">{conn.state === 'connecting' ? <RefreshCw size={26} className="spin" /> : <Plug size={26} />}</div>
                <h3>{conn.state === 'connecting' ? 'Connecting…' : 'Not connected'}</h3>
                <p>{conn.state === 'connecting' ? displayAddress(conn.site!) : 'Use Quickconnect above or open the Site Manager.'}</p>
                {conn.state === 'disconnected' && (
                  <button type="button" className="primary" onClick={() => setDialog('sites')}><Server size={14} /> Open Site Manager</button>
                )}
              </div>
            )
          }
        />
      </main>

      <QueueView
        items={queueItems}
        siteName={siteName}
        onRemove={(ids) => void api.removeTransfers(ids)}
        onRetry={(ids) => void api.retryTransfers(ids)}
        maximized={terminalMax}
        terminal={{
          active: terminalActive,
          status: terminal ? terminalStatus : null,
          label: terminal?.label ?? '',
          select: showTerminal,
          actions: terminal && (
            <>
              <IconButton icon={RotateCw} label="Restart terminal" disabled={!canTerminal} onClick={() => openTerminal(terminal.dir, false)} />
              <IconButton icon={terminalMax ? Minimize2 : Maximize2} label={terminalMax ? 'Restore' : 'Maximize'} onClick={() => setTerminalMax((m) => !m)} />
              <IconButton icon={X} label="Close terminal" onClick={closeTerminal} />
            </>
          ),
          view: terminal ? (
            <Suspense>
              <TerminalView request={terminal} visible={terminalActive} onStatus={setTerminalStatus} />
            </Suspense>
          ) : (
            terminalActive && (
              <div className="term-panel term-empty">
                <SquareTerminal size={24} />
                <p>
                  {canTerminal
                    ? 'Open a shell on the server, in the folder you are viewing.'
                    : connected
                      ? 'The terminal needs an SFTP (SSH) site. FTP servers do not offer a shell.'
                      : 'Connect to an SFTP site to open a terminal on the server.'}
                </p>
                {canTerminal && (
                  <button type="button" className="primary" onClick={() => openTerminal(remote?.path ?? null, false)}>
                    <SquareTerminal size={14} /> Open Terminal
                  </button>
                )}
              </div>
            )
          ),
        }}
      />

      <footer className="statusbar">
        <span className={`status-dot ${conn.state === 'connected' && !conn.secure ? 'insecure' : conn.state}`} aria-hidden />
        {conn.state === 'connected' && statusSite ? (
          <span className={conn.secure ? 'secure' : 'insecure'}>
            {conn.secure ? <ShieldCheck size={14} /> : <ShieldOff size={14} />}
            {statusSite.serverProtocol.toUpperCase()} · {statusSite.host}:{effectivePort(statusSite)}
            {!conn.secure && ' · unencrypted'}
          </span>
        ) : (
          <span className="muted">{conn.state === 'connecting' ? 'Connecting…' : 'Not connected'}</span>
        )}
        {syncBase && <span><ArrowLeftRight size={13} /> Synchronized browsing</span>}
        <span className="spacer" />
        <span>{processing ? '' : 'Queue paused · '}{queueStats.pending ? `${queueStats.pending} queued · ${formatSize(queueStats.bytes)}` : 'Queue empty'}</span>
      </footer>

      {siteMenu && (
        <ContextMenu
          x={siteMenu.x}
          y={siteMenu.y}
          onClose={() => setSiteMenu(null)}
          items={
            sites.sites.length
              ? [...sites.sites].sort((a, b) => `${a.folder}/${a.name}`.localeCompare(`${b.folder}/${b.name}`)).map((s) => ({
                  label: s.folder ? `${s.folder} / ${s.name}` : s.name,
                  icon: siteIcon(s).icon,
                  disabled: !s.host,
                  onClick: () => void connect(() => api.connect(s.id)),
                }))
              : [{ label: 'No saved sites', disabled: true, onClick: () => undefined }]
          }
        />
      )}

      {dialog === 'sites' && (
        <SiteManager
          initial={sites}
          onClose={() => setDialog(null)}
          onSaved={setSites}
          onError={fail}
          onConnect={(id) => {
            setDialog(null)
            void connect(() => api.connect(id))
          }}
        />
      )}
      {dialog === 'settings' && settings && (
        <SettingsDialog
          initial={settings}
          onClose={() => setDialog(null)}
          onSave={(s) => {
            setSettings(s)
            void api.saveSettings(s)
            setDialog(null)
          }}
        />
      )}
      {dialog === 'about' && (
        <Modal title="About RemoteSSH" onClose={() => setDialog(null)} width={380}>
          <div className="about">
            <img src="./icon.png" alt="" width={96} height={96} />
            <h2>RemoteSSH</h2>
            <p>Version {version}</p>
            <p className="muted">SFTP, FTP and FTPS file transfer client.</p>
            <p className="muted">Copyright (c) 2026 Fahed Alhammadi</p>
            <p className="about-links">
              <a href="https://fahed-alhammadi.github.io/RemoteSSH/" target="_blank" rel="noreferrer">Website</a>
              <a href="https://github.com/Fahed-Alhammadi/RemoteSSH" target="_blank" rel="noreferrer">GitHub</a>
            </p>
          </div>
        </Modal>
      )}
      {prompt && (
        <PromptDialog
          key={prompt.key}
          request={prompt.request}
          done={(value) => {
            prompt.resolve(value)
            setPrompts((p) => p.slice(1))
          }}
        />
      )}
    </div>
  )
}

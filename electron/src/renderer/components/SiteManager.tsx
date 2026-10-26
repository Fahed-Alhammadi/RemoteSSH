import { useMemo, useState } from 'react'
import {
  ArrowDownUp,
  Copy,
  FileDown,
  FileUp,
  Folder,
  FolderOpen,
  Lock,
  Plug,
  Plus,
  Server,
  Trash2,
  type LucideIcon,
} from 'lucide-react'
import { makeSite, newID } from '../../shared/site'
import type { FTPEncryption, LogonType, ServerProtocol, Site, SitesState } from '../../shared/types'
import { errorMessage } from '../../shared/util'
import { api } from '../api'
import { ContextMenu, Modal } from './ui'

const protocolLabels: Record<ServerProtocol, string> = {
  sftp: 'SFTP – SSH File Transfer Protocol',
  ftp: 'FTP – File Transfer Protocol',
}
const encryptionLabels: Record<FTPEncryption, string> = {
  explicitIfAvailable: 'Use explicit FTP over TLS if available',
  requireExplicit: 'Require explicit FTP over TLS',
  requireImplicit: 'Require implicit FTP over TLS',
  plain: 'Only use plain FTP (insecure)',
}
const logonLabels: Record<LogonType, string> = {
  anonymous: 'Anonymous',
  normal: 'Normal',
  askForPassword: 'Ask for password',
  keyFile: 'Key file',
}

export function siteIcon(site: Site): { icon: LucideIcon; color: string } {
  if (site.serverProtocol === 'sftp') return { icon: Lock, color: 'var(--c-green)' }
  return site.encryption === 'plain' ? { icon: Server, color: 'var(--c-orange)' } : { icon: Server, color: 'var(--c-blue)' }
}

export function SiteManager(props: {
  initial: SitesState
  onClose: () => void
  onSaved: (state: SitesState) => void
  onConnect: (id: string) => void
  onError: (message: string) => void
}) {
  const [sites, setSites] = useState<Site[]>(props.initial.sites)
  const [stored, setStored] = useState(new Set(props.initial.withPassword))
  const [passwords, setPasswords] = useState<Record<string, string | null>>({})
  const [selectedID, setSelectedID] = useState<string | null>(props.initial.sites[0]?.id ?? null)
  const [tab, setTab] = useState<'general' | 'advanced'>('general')
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null)
  const canStore = props.initial.canStorePasswords
  const site = sites.find((s) => s.id === selectedID) ?? null

  const tree = useMemo(() => {
    const folders = new Map<string, Site[]>()
    for (const s of [...sites].sort((a, b) => a.name.localeCompare(b.name))) {
      const list = folders.get(s.folder) ?? []
      list.push(s)
      folders.set(s.folder, list)
    }
    return [...folders.entries()].sort(([a], [b]) => (a === '' ? -1 : b === '' ? 1 : a.localeCompare(b)))
  }, [sites])

  const update = (patch: Partial<Site>) => site && setSites((all) => all.map((s) => (s.id === site.id ? { ...s, ...patch } : s)))

  async function save(): Promise<boolean> {
    try {
      const state = await api.saveSites({ sites, passwords })
      setStored(new Set(state.withPassword))
      setPasswords({})
      props.onSaved(state)
      return true
    } catch (e) {
      props.onError(errorMessage(e))
      return false
    }
  }

  function add(fields: Partial<Site> = {}) {
    const s = makeSite({ folder: site?.folder ?? '', ...fields })
    setSites((all) => [...all, s])
    setSelectedID(s.id)
    setTab('general')
  }

  async function importExport(kind: 'import' | 'export') {
    if (!(await save())) return
    try {
      if (kind === 'export') return await api.exportSites()
      const state = await api.importSites()
      if (!state) return
      setSites(state.sites)
      setStored(new Set(state.withPassword))
      props.onSaved(state)
    } catch (e) {
      props.onError(errorMessage(e))
    }
  }

  const folders = [...new Set(sites.map((s) => s.folder).filter(Boolean))].sort()
  const passwordValue = site ? (passwords[site.id] ?? '') : ''
  const hasStored = site ? stored.has(site.id) && passwords[site.id] !== null : false

  return (
    <Modal title="Site Manager" icon={Server} onClose={props.onClose} width={860}
      footer={<>
        <button type="button" onClick={(e) => setMenu({ x: e.clientX, y: e.clientY - 80 })}><ArrowDownUp size={14} /> Import / Export</button>
        <span className="spacer" />
        <button type="button" onClick={props.onClose}>Cancel</button>
        <button type="button" onClick={async () => (await save()) && props.onClose()}>Save</button>
        <button type="button" className="primary" disabled={!site?.host}
          onClick={async () => site && (await save()) && props.onConnect(site.id)}><Plug size={14} /> Connect</button>
      </>}>
      <div className="site-manager">
        <aside>
          <div className="segmented">
            <button type="button" onClick={() => add()} title="New site"><Plus size={15} /> New</button>
            <button type="button" disabled={!site} title="Duplicate" onClick={() => site && add({ ...site, id: newID(), name: `${site.name} copy` })}><Copy size={15} /></button>
            <button type="button" disabled={!site} title="Delete" className="danger"
              onClick={() => {
                if (!site) return
                setSites((all) => all.filter((s) => s.id !== site.id))
                setSelectedID(null)
              }}><Trash2 size={15} /></button>
          </div>
          <div className="site-tree" role="tree">
            {tree.length === 0 && <div className="empty">No sites yet</div>}
            {tree.map(([folder, list]) => (
              <div key={folder} role="group">
                {folder && <div className="tree-folder"><FolderOpen size={14} /> {folder}</div>}
                {list.map((s) => {
                  const { icon: Icon, color } = siteIcon(s)
                  return (
                    <div key={s.id} role="treeitem" aria-selected={s.id === selectedID}
                      className={`tree-site${s.id === selectedID ? ' selected' : ''}${folder ? ' nested' : ''}`}
                      onClick={() => setSelectedID(s.id)}
                      onDoubleClick={async () => s.host && (await save()) && props.onConnect(s.id)}>
                      <Icon size={15} color={color} />
                      <span>{s.name || 'Unnamed'}</span>
                    </div>
                  )
                })}
              </div>
            ))}
          </div>
        </aside>
        {site ? (
          <div className="site-form">
            <div className="tabs small">
              <button type="button" className={tab === 'general' ? 'active' : ''} onClick={() => setTab('general')}>General</button>
              <button type="button" className={tab === 'advanced' ? 'active' : ''} onClick={() => setTab('advanced')}>Advanced</button>
            </div>
            {tab === 'general' ? (
              <div className="form-grid">
                <label>Name</label>
                <input value={site.name} onChange={(e) => update({ name: e.target.value })} />
                <label>Folder</label>
                <input value={site.folder} list="site-folders" placeholder="None" onChange={(e) => update({ folder: e.target.value.replace(/^\/+|\/+$/g, '') })} />
                <datalist id="site-folders">{folders.map((f) => <option key={f} value={f} />)}</datalist>
                <label>Protocol</label>
                <select value={site.serverProtocol} onChange={(e) => update({ serverProtocol: e.target.value as ServerProtocol })}>
                  {Object.entries(protocolLabels).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                </select>
                <label>Host</label>
                <div className="host-port">
                  <input value={site.host} placeholder="example.com" spellCheck={false} onChange={(e) => update({ host: e.target.value.trim() })} />
                  <input value={site.port || ''} placeholder={site.serverProtocol === 'sftp' ? '22' : site.encryption === 'requireImplicit' ? '990' : '21'}
                    aria-label="Port" inputMode="numeric" onChange={(e) => update({ port: Number(e.target.value.replace(/\D/g, '')) || 0 })} />
                </div>
                {site.serverProtocol === 'ftp' && (<>
                  <label>Encryption</label>
                  <select value={site.encryption} onChange={(e) => update({ encryption: e.target.value as FTPEncryption })}>
                    {Object.entries(encryptionLabels).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                  </select>
                </>)}
                <label>Logon type</label>
                <select value={site.logonType} onChange={(e) => update({ logonType: e.target.value as LogonType })}>
                  {Object.entries(logonLabels)
                    .filter(([k]) => (site.serverProtocol === 'sftp' ? k !== 'anonymous' : k !== 'keyFile'))
                    .map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                </select>
                {site.logonType !== 'anonymous' && (<>
                  <label>User</label>
                  <input value={site.user} spellCheck={false} onChange={(e) => update({ user: e.target.value })} />
                </>)}
                {site.logonType === 'normal' && (<>
                  <label>Password</label>
                  <div className="stack">
                    <input type="password" value={passwordValue} disabled={!canStore}
                      placeholder={!canStore ? 'Asked when connecting' : hasStored ? '•••••••• (saved)' : ''}
                      onChange={(e) => setPasswords((p) => ({ ...p, [site.id]: e.target.value || (hasStored ? null : '') }))} />
                    {!canStore && <small className="muted">No secure password storage (keyring) is available on this system.</small>}
                  </div>
                </>)}
                {site.logonType === 'keyFile' && (<>
                  <label>Key file</label>
                  <div className="host-port">
                    <input value={site.keyFilePath} placeholder="~/.ssh/id_ed25519" spellCheck={false} onChange={(e) => update({ keyFilePath: e.target.value })} />
                    <button type="button" onClick={async () => {
                      const p = await api.chooseKeyFile()
                      if (p) update({ keyFilePath: p })
                    }}>Browse…</button>
                  </div>
                </>)}
                <label>Comments</label>
                <textarea rows={3} value={site.comments} onChange={(e) => update({ comments: e.target.value })} />
              </div>
            ) : (
              <div className="form-grid">
                <label>Default local directory</label>
                <div className="host-port">
                  <input value={site.defaultLocalDirectory} onChange={(e) => update({ defaultLocalDirectory: e.target.value })} />
                  <button type="button" onClick={async () => {
                    const p = await api.chooseFolder()
                    if (p) update({ defaultLocalDirectory: p })
                  }}><Folder size={14} /></button>
                </div>
                <label>Default remote directory</label>
                <input value={site.defaultRemoteDirectory} placeholder="/" spellCheck={false} onChange={(e) => update({ defaultRemoteDirectory: e.target.value })} />
                {site.serverProtocol === 'ftp' && (<>
                  <label>Transfer mode</label>
                  <select value="passive" disabled title="This version always uses passive mode">
                    <option value="passive">Passive</option>
                  </select>
                  <label>Certificate</label>
                  <label className="check">
                    <input type="checkbox" checked={site.trustInvalidCertificate} onChange={(e) => update({ trustInvalidCertificate: e.target.checked })} />
                    Trust this server’s certificate even if it cannot be verified
                  </label>
                </>)}
              </div>
            )}
          </div>
        ) : (
          <div className="site-form empty">Select a site or create a new one.</div>
        )}
      </div>
      {menu && (
        <ContextMenu x={menu.x} y={menu.y} onClose={() => setMenu(null)} items={[
          { label: 'Import from RemoteSSH…', icon: FileDown, onClick: () => void importExport('import') },
          { label: 'Export Sites…', icon: FileUp, onClick: () => void importExport('export'), disabled: !sites.length },
        ]} />
      )}
    </Modal>
  )
}

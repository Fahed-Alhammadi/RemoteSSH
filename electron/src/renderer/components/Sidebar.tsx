import { useMemo } from 'react'
import { FolderOpen, Plus, Settings, SlidersHorizontal } from 'lucide-react'
import type { ConnectionInfo, Site } from '../../shared/types'
import { siteIcon } from './SiteManager'

/** Saved sites, one click to connect, with the connected site marked. */
export function Sidebar(props: {
  sites: Site[]
  connection: ConnectionInfo
  onConnect: (id: string) => void
  onManage: () => void
  onSettings: () => void
}) {
  const groups = useMemo(() => {
    const byFolder = new Map<string, Site[]>()
    for (const s of [...props.sites].sort((a, b) => a.name.localeCompare(b.name))) {
      byFolder.set(s.folder, [...(byFolder.get(s.folder) ?? []), s])
    }
    return [...byFolder.entries()].sort(([a], [b]) => (a === '' ? -1 : b === '' ? 1 : a.localeCompare(b)))
  }, [props.sites])
  const current = props.connection.site?.id

  return (
    <aside className="sidebar">
      <div className="sidebar-brand">
        <img src="./icon.png" alt="" width={24} height={24} />
        <span>RemoteSSH</span>
      </div>
      <div className="sidebar-head">
        <h2>Sites</h2>
        <button type="button" className="icon-button small" aria-label="Manage sites" title="Site Manager" onClick={props.onManage}>
          <SlidersHorizontal size={15} strokeWidth={1.75} />
        </button>
      </div>
      <nav className="site-list" aria-label="Saved sites">
        {groups.length === 0 && (
          <div className="sidebar-empty">
            <p>Save the servers you use often and connect with one click.</p>
            <button type="button" onClick={props.onManage}><Plus size={14} /> Add a site</button>
          </div>
        )}
        {groups.map(([folder, sites]) => (
          <div key={folder} className="site-group">
            {folder && <div className="site-folder"><FolderOpen size={13} /> {folder}</div>}
            {sites.map((s) => {
              const { icon: Icon, color } = siteIcon(s)
              const active = s.id === current && props.connection.state !== 'disconnected'
              return (
                <button
                  key={s.id}
                  type="button"
                  className={`site-item${active ? ' active' : ''}${folder ? ' nested' : ''}`}
                  disabled={!s.host}
                  title={s.host ? `Connect to ${s.name}` : 'This site has no host name'}
                  onClick={() => props.onConnect(s.id)}
                >
                  <Icon size={15} strokeWidth={1.75} style={{ color }} />
                  <span className="site-text">
                    <span className="site-name">{s.name}</span>
                    <span className="site-host">{s.user ? `${s.user}@` : ''}{s.host}</span>
                  </span>
                  {active && <span className={`status-dot ${props.connection.state}`} aria-label={props.connection.state === 'connected' ? 'Connected' : 'Connecting'} />}
                </button>
              )
            })}
          </div>
        ))}
      </nav>
      <div className="sidebar-foot">
        <button type="button" className="sidebar-link" onClick={props.onSettings}><Settings size={15} strokeWidth={1.75} /> Settings</button>
      </div>
    </aside>
  )
}

import { useLayoutEffect, useMemo, useState, type ReactNode } from 'react'
import {
  ArrowDownToLine,
  ArrowUpFromLine,
  CircleAlert,
  CircleCheck,
  Clock,
  Info,
  ListChecks,
  MessageSquareReply,
  RotateCcw,
  SendHorizontal,
  SquareTerminal,
  Trash2,
  X,
} from 'lucide-react'
import type { LogKind, LogLine, TransferItem } from '../../shared/types'
import { formatSize } from '../../shared/util'
import type { TerminalStatus } from './TerminalView'
import { ContextMenu, useVirtualRows } from './ui'

const logIcons: Record<LogKind, { icon: typeof Info; cls: string }> = {
  status: { icon: Info, cls: 'log-status' },
  command: { icon: SendHorizontal, cls: 'log-command' },
  response: { icon: MessageSquareReply, cls: 'log-response' },
  error: { icon: CircleAlert, cls: 'log-error' },
  listing: { icon: ListChecks, cls: 'log-status' },
}

const timeFormat = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' })

export function LogView({ lines }: { lines: LogLine[] }) {
  const virtual = useVirtualRows(lines.length, 20)
  // Stick to the bottom while the user is already there.
  useLayoutEffect(() => {
    const el = virtual.ref.current
    if (el && el.scrollHeight - el.scrollTop - el.clientHeight < 60) el.scrollTop = el.scrollHeight
  }, [lines.length, virtual.ref])
  return (
    <div className="log" ref={virtual.ref} role="log">
      {lines.length === 0 && <div className="empty small">No messages yet. Connection activity appears here.</div>}
      <div style={{ height: virtual.padTop }} />
      {lines.slice(virtual.start, virtual.end).map((l) => {
        const { icon: Icon, cls } = logIcons[l.kind]
        return (
          <div key={l.id} className={`log-line ${cls}`}>
            <span className="log-time">{timeFormat.format(l.time)}</span>
            <Icon size={13} />
            <span className="log-text">{l.text}</span>
          </div>
        )
      })}
      <div style={{ height: virtual.padBottom }} />
    </div>
  )
}

type Tab = 'queued' | 'failed' | 'finished'

const emptyText: Record<Tab, string> = {
  queued: 'Drag files between the panes to transfer them.',
  failed: 'No failed transfers.',
  finished: 'Finished transfers appear here.',
}

const terminalStatusText: Record<TerminalStatus, string> = { connecting: 'connecting…', connected: '', disconnected: 'ended' }

/** The terminal tab shares the card with the queue. */
export interface TerminalTab {
  active: boolean
  /** Null until a terminal has been opened. */
  status: TerminalStatus | null
  label: string
  select: (active: boolean) => void
  /** Buttons shown on the right of the tab bar while the terminal is active. */
  actions: ReactNode
  view: ReactNode
}

export function QueueView(props: {
  items: TransferItem[]
  siteName: (id: string) => string
  onRemove: (ids: string[]) => void
  onRetry: (ids: string[]) => void
  terminal: TerminalTab
  maximized: boolean
}) {
  const [tab, setTab] = useState<Tab>('queued')
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null)
  const groups = useMemo(() => {
    const g: Record<Tab, TransferItem[]> = { queued: [], failed: [], finished: [] }
    for (const i of props.items) g[i.status === 'transferring' ? 'queued' : i.status].push(i)
    g.queued.sort((a, b) => Number(b.status === 'transferring') - Number(a.status === 'transferring'))
    g.finished.sort((a, b) => (b.finishedAt ?? 0) - (a.finishedAt ?? 0))
    return g
  }, [props.items])
  const rows = groups[tab]
  const virtual = useVirtualRows(rows.length, 34)
  const ids = rows.filter((r) => selected.has(r.id)).map((r) => r.id)

  const tabs: { id: Tab; label: string; icon: typeof Clock }[] = [
    { id: 'queued', label: 'Queued', icon: Clock },
    { id: 'failed', label: 'Failed', icon: CircleAlert },
    { id: 'finished', label: 'Done', icon: CircleCheck },
  ]
  const term = props.terminal
  const termActive = term.active
  return (
    <div className={`queue${termActive ? ' with-terminal' : ''}${termActive && props.maximized ? ' maximized' : ''}`}>
      <div className="tabs" role="tablist">
        {tabs.map((t) => (
          <button
            key={t.id}
            type="button"
            role="tab"
            aria-selected={!termActive && tab === t.id}
            className={!termActive && tab === t.id ? 'active' : ''}
            onClick={() => {
              setTab(t.id)
              term.select(false)
            }}
          >
            <t.icon size={14} />
            {t.label}
            <span className="badge">{groups[t.id].length}</span>
          </button>
        ))}
        <button type="button" role="tab" aria-selected={termActive} className={termActive ? 'active' : ''} onClick={() => term.select(true)} title={term.label || 'Terminal (Ctrl+`)'}>
          <SquareTerminal size={14} />
          Terminal
          {term.status && <span className={`status-dot ${term.status}`} aria-hidden />}
          {term.status && terminalStatusText[term.status] && <span className="muted">{terminalStatusText[term.status]}</span>}
        </button>
        {termActive && (
          <>
            <span className="spacer" />
            <span className="term-label">{term.label}</span>
            {term.actions}
          </>
        )}
      </div>
      {term.view}
      <div
        hidden={termActive}
        className="queue-rows"
        ref={virtual.ref}
        tabIndex={0}
        onKeyDown={(e) => e.key === 'Delete' && ids.length && props.onRemove(ids)}
        onContextMenu={(e) => {
          e.preventDefault()
          setMenu({ x: e.clientX, y: e.clientY })
        }}
      >
        {rows.length === 0 && <div className="empty">{emptyText[tab]}</div>}
        <div style={{ height: virtual.padTop }} />
        {rows.slice(virtual.start, virtual.end).map((item) => {
          const pct = item.size ? Math.min(100, (item.transferred / item.size) * 100) : 0
          const Dir = item.direction === 'download' ? ArrowDownToLine : ArrowUpFromLine
          return (
            <div
              key={item.id}
              className={`queue-row${selected.has(item.id) ? ' selected' : ''}`}
              onMouseDown={(e) => {
                if (e.button === 2 && selected.has(item.id)) return
                const next = new Set(e.ctrlKey || e.metaKey ? selected : [])
                if (next.has(item.id)) next.delete(item.id)
                else next.add(item.id)
                setSelected(next)
              }}
            >
              <Dir size={15} className={item.direction} />
              <div className="queue-paths">
                <span className="queue-local" title={item.localPath}>{item.localPath}</span>
                <span className="queue-remote" title={`${props.siteName(item.siteID)} ${item.remotePath}`}>
                  {props.siteName(item.siteID)} · {item.remotePath}
                </span>
              </div>
              <div className="queue-status">
                {item.status === 'transferring' ? (
                  <>
                    <div className="progress"><div style={{ width: `${pct}%` }} /></div>
                    <span>
                      {formatSize(item.transferred)}
                      {item.size ? ` / ${formatSize(item.size)}` : ''}
                      {item.speed ? ` · ${formatSize(item.speed)}/s` : ''}
                    </span>
                  </>
                ) : item.status === 'failed' ? (
                  <span className="error-text" title={item.error}>{item.error}</span>
                ) : item.status === 'finished' ? (
                  <span>{item.error ?? formatSize(item.size)}</span>
                ) : (
                  <span>{formatSize(item.size)}</span>
                )}
              </div>
            </div>
          )
        })}
        <div style={{ height: virtual.padBottom }} />
      </div>
      {menu && (
        <ContextMenu
          x={menu.x}
          y={menu.y}
          onClose={() => setMenu(null)}
          items={[
            { label: 'Retry', icon: RotateCcw, onClick: () => props.onRetry(ids), disabled: tab !== 'failed' || !ids.length },
            { label: tab === 'queued' ? 'Cancel' : 'Remove', icon: tab === 'queued' ? X : Trash2, onClick: () => props.onRemove(ids), disabled: !ids.length },
            'separator',
            { label: 'Select All', onClick: () => setSelected(new Set(rows.map((r) => r.id))) },
            { label: `Remove All ${tabs.find((t) => t.id === tab)!.label}`, icon: Trash2, danger: true, onClick: () => props.onRemove(rows.map((r) => r.id)), disabled: !rows.length },
          ]}
        />
      )}
    </div>
  )
}

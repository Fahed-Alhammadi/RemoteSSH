import { useLayoutEffect, useMemo, useState, type ReactNode } from 'react'
import {
  ArrowDownToLine,
  ArrowDownUp,
  ArrowUpFromLine,
  ChevronDown,
  ChevronUp,
  CircleAlert,
  CircleCheck,
  Clock,
  Info,
  ListChecks,
  MessageSquareReply,
  RotateCcw,
  ScrollText,
  SendHorizontal,
  SquareTerminal,
  Trash2,
  X,
} from 'lucide-react'
import type { LogKind, LogLine, TransferItem } from '../../shared/types'
import { formatSize } from '../../shared/util'
import type { TerminalStatus } from './TerminalView'
import { ContextMenu, IconButton, useVirtualRows } from './ui'

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

type Filter = 'queued' | 'failed' | 'finished'
export type DockPanel = 'activity' | 'transfers' | 'terminal'

const emptyText: Record<Filter, string> = {
  queued: 'Drag files between the panes to transfer them.',
  failed: 'No failed transfers.',
  finished: 'Finished transfers appear here.',
}

const filters: { id: Filter; label: string; icon: typeof Clock }[] = [
  { id: 'queued', label: 'Queued', icon: Clock },
  { id: 'failed', label: 'Failed', icon: CircleAlert },
  { id: 'finished', label: 'Done', icon: CircleCheck },
]

const terminalStatusText: Record<TerminalStatus, string> = { connecting: 'connecting…', connected: '', disconnected: 'ended' }

/** What the dock needs to show the terminal tab. */
export interface DockTerminal {
  /** Null until a terminal has been opened. */
  status: TerminalStatus | null
  label: string
  /** Buttons shown on the right of the tab bar while the terminal tab is open. */
  actions: ReactNode
  view: ReactNode
}

/** The bottom dock: Activity (message log), Transfers and Terminal tabs, resizable and collapsible. */
export function Dock(props: {
  panel: DockPanel
  open: boolean
  maximized: boolean
  height: number
  onPanel: (panel: DockPanel) => void
  onOpen: (open: boolean) => void
  onResize: (height: number) => void
  log: LogLine[]
  items: TransferItem[]
  siteName: (id: string) => string
  onRemove: (ids: string[]) => void
  onRetry: (ids: string[]) => void
  terminal: DockTerminal
}) {
  const [filter, setFilter] = useState<Filter>('queued')
  const groups = useMemo(() => {
    const g: Record<Filter, TransferItem[]> = { queued: [], failed: [], finished: [] }
    for (const i of props.items) g[i.status === 'transferring' ? 'queued' : i.status].push(i)
    g.queued.sort((a, b) => Number(b.status === 'transferring') - Number(a.status === 'transferring'))
    g.finished.sort((a, b) => (b.finishedAt ?? 0) - (a.finishedAt ?? 0))
    return g
  }, [props.items])
  const errors = useMemo(() => props.log.filter((l) => l.kind === 'error').length, [props.log])
  const { panel, open, terminal } = props
  const show = (p: DockPanel) => {
    props.onPanel(p)
    props.onOpen(true)
  }

  // Drag the top edge to resize.
  const startResize = (e: React.PointerEvent) => {
    const startY = e.clientY
    const startHeight = props.height
    const move = (ev: PointerEvent) => props.onResize(Math.min(window.innerHeight - 240, Math.max(140, startHeight + startY - ev.clientY)))
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }

  const tab = (id: DockPanel, icon: typeof Clock, label: string, extra?: ReactNode) => {
    const Icon = icon
    const active = open && panel === id
    return (
      <button type="button" role="tab" aria-selected={active} className={active ? 'active' : ''} onClick={() => (active ? props.onOpen(false) : show(id))}>
        <Icon size={14} />
        {label}
        {extra}
      </button>
    )
  }

  return (
    <section
      className={`dock${open ? '' : ' collapsed'}${open && props.maximized ? ' maximized' : ''}`}
      style={open && !props.maximized ? { height: props.height } : undefined}
    >
      {open && !props.maximized && <div className="dock-resize" onPointerDown={startResize} aria-hidden />}
      <div className="dock-bar" role="tablist">
        {tab('activity', ScrollText, 'Activity', errors > 0 && <span className="badge error">{errors}</span>)}
        {tab('transfers', ArrowDownUp, 'Transfers', groups.queued.length > 0 && <span className="badge">{groups.queued.length}</span>)}
        {tab('terminal', SquareTerminal, 'Terminal', terminal.status && (
          <>
            <span className={`status-dot ${terminal.status}`} aria-hidden />
            {terminalStatusText[terminal.status] && <span className="muted">{terminalStatusText[terminal.status]}</span>}
          </>
        ))}
        <span className="spacer" />
        {open && panel === 'transfers' && (
          <div className="segmented" role="group" aria-label="Show transfers">
            {filters.map((f) => (
              <button key={f.id} type="button" className={filter === f.id ? 'active' : ''} aria-pressed={filter === f.id} onClick={() => setFilter(f.id)}>
                {f.label}
                <span className="count">{groups[f.id].length}</span>
              </button>
            ))}
          </div>
        )}
        {open && panel === 'terminal' && (
          <>
            {terminal.label && <span className="term-label">{terminal.label}</span>}
            {terminal.actions}
          </>
        )}
        <IconButton icon={open ? ChevronDown : ChevronUp} label={open ? 'Hide panel' : 'Show panel'} onClick={() => props.onOpen(!open)} />
      </div>
      {open && panel === 'activity' && <LogView lines={props.log} />}
      {open && panel === 'transfers' && (
        <TransferList items={groups[filter]} filter={filter} siteName={props.siteName} onRemove={props.onRemove} onRetry={props.onRetry} />
      )}
      {terminal.view}
    </section>
  )
}

function TransferList(props: {
  items: TransferItem[]
  filter: Filter
  siteName: (id: string) => string
  onRemove: (ids: string[]) => void
  onRetry: (ids: string[]) => void
}) {
  const { items: rows, filter } = props
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null)
  const virtual = useVirtualRows(rows.length, 40)
  const ids = rows.filter((r) => selected.has(r.id)).map((r) => r.id)
  return (
    <div
      className="queue-rows"
      ref={virtual.ref}
      tabIndex={0}
      onKeyDown={(e) => e.key === 'Delete' && ids.length && props.onRemove(ids)}
      onContextMenu={(e) => {
        e.preventDefault()
        setMenu({ x: e.clientX, y: e.clientY })
      }}
    >
      {rows.length === 0 && <div className="empty">{emptyText[filter]}</div>}
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
      {menu && (
        <ContextMenu
          x={menu.x}
          y={menu.y}
          onClose={() => setMenu(null)}
          items={[
            { label: 'Retry', icon: RotateCcw, onClick: () => props.onRetry(ids), disabled: filter !== 'failed' || !ids.length },
            { label: filter === 'queued' ? 'Cancel' : 'Remove', icon: filter === 'queued' ? X : Trash2, onClick: () => props.onRemove(ids), disabled: !ids.length },
            'separator',
            { label: 'Select All', onClick: () => setSelected(new Set(rows.map((r) => r.id))) },
            { label: `Remove All ${filters.find((f) => f.id === filter)!.label}`, icon: Trash2, danger: true, onClick: () => props.onRemove(rows.map((r) => r.id)), disabled: !rows.length },
          ]}
        />
      )}
    </div>
  )
}

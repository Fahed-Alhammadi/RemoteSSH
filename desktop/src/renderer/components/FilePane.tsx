import { useEffect, useMemo, useRef, useState, type DragEvent, type KeyboardEvent, type MouseEvent, type ReactNode } from 'react'
import { ArrowDown, ArrowUp, CornerLeftUp, RefreshCw, Search, X, type LucideIcon } from 'lucide-react'
import type { FileEntry } from '../../shared/types'
import { fileType, formatDate, formatSize } from '../../shared/util'
import { FileIcon } from './FileIcon'
import { ContextMenu, IconButton, useVirtualRows, type MenuEntry } from './ui'

export type Side = 'local' | 'remote'
export type CompareMark = 'lonely' | 'different' | 'newer'
export interface DragPayload {
  side: Side
  dir: string
  entries: FileEntry[]
}

type SortKey = 'name' | 'size' | 'type' | 'modified' | 'permissions' | 'owner'
const ROW = 24
const DRAG_TYPE = 'application/x-remotessh'

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })

export function FilePane(props: {
  side: Side
  title: string
  icon: LucideIcon
  path: string
  canGoUp: boolean
  entries: FileEntry[]
  showHidden: boolean
  comparison: Map<string, CompareMark> | null
  selection: Set<string>
  onSelection: (s: Set<string>) => void
  onNavigate: (path: string) => void
  onUp: () => void
  onRefresh: () => void
  onOpen: (entry: FileEntry) => void
  onDrop: (payload: DragPayload | { osPaths: string[] }, targetDir: string | null) => void
  onDelete: (entries: FileEntry[]) => void
  onRename: (entry: FileEntry) => void
  menu: (entries: FileEntry[]) => MenuEntry[]
  placeholder?: ReactNode
  loading?: boolean
  showOwner?: boolean
  pathForFile: (f: File) => string
}) {
  const { entries, showHidden, selection, onSelection, comparison } = props
  const [sort, setSort] = useState<{ key: SortKey; asc: boolean }>({ key: 'name', asc: true })
  const [filter, setFilter] = useState('')
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null)
  const [dropTarget, setDropTarget] = useState<string | null>(null)
  const anchor = useRef<number | null>(null)

  useEffect(() => setFilter(''), [props.path])

  const rows = useMemo(() => {
    const needle = filter.toLowerCase()
    const visible = entries.filter(
      (e) => (showHidden || !e.name.startsWith('.')) && (!needle || e.name.toLowerCase().includes(needle)),
    )
    const dir = sort.asc ? 1 : -1
    const value = (e: FileEntry): string | number => {
      switch (sort.key) {
        case 'size': return e.size ?? -1
        case 'type': return fileType(e.name, e.isDirectory)
        case 'modified': return e.modified ?? 0
        case 'permissions': return e.permissions
        case 'owner': return `${e.owner}/${e.group}`
        default: return e.name
      }
    }
    return visible.sort((a, b) => {
      if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1
      const va = value(a)
      const vb = value(b)
      const c = typeof va === 'number' && typeof vb === 'number' ? va - vb : collator.compare(String(va), String(vb))
      return (c || collator.compare(a.name, b.name)) * dir
    })
  }, [entries, showHidden, filter, sort])

  const selected = useMemo(() => rows.filter((r) => selection.has(r.name)), [rows, selection])
  const virtual = useVirtualRows(rows.length, ROW)

  function click(e: MouseEvent, index: number) {
    const name = rows[index].name
    if (e.shiftKey && anchor.current != null) {
      const [a, b] = [Math.min(anchor.current, index), Math.max(anchor.current, index)]
      const next = new Set(e.ctrlKey || e.metaKey ? selection : [])
      for (let i = a; i <= b; i++) next.add(rows[i].name)
      onSelection(next)
      return
    }
    anchor.current = index
    if (e.ctrlKey || e.metaKey) {
      const next = new Set(selection)
      if (next.has(name)) next.delete(name)
      else next.add(name)
      onSelection(next)
    } else if (!(e.button === 2 && selection.has(name))) {
      onSelection(new Set([name]))
    }
  }

  function key(e: KeyboardEvent) {
    if ((e.target as HTMLElement).tagName === 'INPUT') return
    const idx = rows.findIndex((r) => r.name === [...selection].at(-1))
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault()
      const next = Math.max(0, Math.min(rows.length - 1, idx + (e.key === 'ArrowDown' ? 1 : -1)))
      if (rows[next]) {
        anchor.current = next
        onSelection(new Set([rows[next].name]))
        const el = virtual.ref.current
        if (el) {
          const top = next * ROW
          if (top < el.scrollTop) el.scrollTop = top
          else if (top + ROW > el.scrollTop + el.clientHeight - ROW) el.scrollTop = top + 2 * ROW - el.clientHeight
        }
      }
    } else if (e.key === 'Enter' && selected.length === 1) {
      props.onOpen(selected[0])
    } else if (e.key === 'Backspace' && props.canGoUp) {
      props.onUp()
    } else if (e.key === 'Delete' && selected.length) {
      props.onDelete(selected)
    } else if (e.key === 'F2' && selected.length === 1) {
      props.onRename(selected[0])
    } else if (e.key === 'a' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault()
      onSelection(new Set(rows.map((r) => r.name)))
    }
  }

  function dragStart(e: DragEvent, entry: FileEntry) {
    const dragged = selection.has(entry.name) ? selected : [entry]
    if (!selection.has(entry.name)) onSelection(new Set([entry.name]))
    const payload: DragPayload = { side: props.side, dir: props.path, entries: dragged }
    e.dataTransfer.setData(DRAG_TYPE, JSON.stringify(payload))
    e.dataTransfer.effectAllowed = 'copy'
  }

  function accepts(e: DragEvent): boolean {
    if (props.placeholder) return false
    if (e.dataTransfer.types.includes(DRAG_TYPE)) return true
    return props.side === 'remote' && e.dataTransfer.types.includes('Files')
  }

  function drop(e: DragEvent, targetDir: string | null) {
    e.preventDefault()
    e.stopPropagation()
    setDropTarget(null)
    const raw = e.dataTransfer.getData(DRAG_TYPE)
    if (raw) {
      const payload = JSON.parse(raw) as DragPayload
      if (payload.side !== props.side) props.onDrop(payload, targetDir)
      return
    }
    const osPaths = [...e.dataTransfer.files].map(props.pathForFile).filter(Boolean)
    if (osPaths.length && props.side === 'remote') props.onDrop({ osPaths }, targetDir)
  }

  const header = (label: string, k: SortKey, cls: string) => (
    <div className={`cell ${cls}`} role="columnheader" onClick={() => setSort((s) => ({ key: k, asc: s.key === k ? !s.asc : true }))}>
      {label}
      {sort.key === k && (sort.asc ? <ArrowUp size={12} /> : <ArrowDown size={12} />)}
    </div>
  )

  return (
    <section className={`pane pane-${props.side}`} onKeyDown={key}>
      <PathBar icon={props.icon} title={props.title} path={props.path} disabled={!!props.placeholder} onSubmit={props.onNavigate} />
      <div className="pane-tools">
        <IconButton icon={CornerLeftUp} label="Parent directory" onClick={props.onUp} disabled={!props.canGoUp || !!props.placeholder} />
        <IconButton icon={RefreshCw} label="Refresh" onClick={props.onRefresh} disabled={!!props.placeholder} />
        <label className="filter">
          <Search size={14} />
          <input value={filter} placeholder="Filter" onChange={(e) => setFilter(e.target.value)} disabled={!!props.placeholder} />
          {filter && (
            <button type="button" onClick={() => setFilter('')} aria-label="Clear filter">
              <X size={12} />
            </button>
          )}
        </label>
      </div>
      {props.placeholder ? (
        <div className="pane-placeholder">{props.placeholder}</div>
      ) : (
        <div className={`table${props.showOwner ? ' with-owner' : ''}`} role="grid">
          <div className="row header" role="row">
            {header('Name', 'name', 'name')}
            {header('Size', 'size', 'size')}
            {header('Type', 'type', 'type')}
            {header('Modified', 'modified', 'modified')}
            {header('Permissions', 'permissions', 'perms')}
            {props.showOwner && header('Owner/Group', 'owner', 'owner')}
          </div>
          <div
            className={`rows${dropTarget === '' ? ' drop' : ''}${props.loading ? ' loading' : ''}`}
            ref={virtual.ref}
            tabIndex={0}
            onMouseDown={(e) => e.target === e.currentTarget && onSelection(new Set())}
            onContextMenu={(e) => {
              e.preventDefault()
              if (e.target === e.currentTarget) onSelection(new Set())
              setMenu({ x: e.clientX, y: e.clientY })
            }}
            onDragOver={(e) => {
              if (!accepts(e)) return
              e.preventDefault()
              e.dataTransfer.dropEffect = 'copy'
              if (dropTarget !== '' && e.target === e.currentTarget) setDropTarget('')
            }}
            onDragLeave={(e) => e.target === e.currentTarget && setDropTarget(null)}
            onDrop={(e) => drop(e, null)}
          >
            <div style={{ height: virtual.padTop }} />
            {rows.slice(virtual.start, virtual.end).map((entry, i) => {
              const index = virtual.start + i
              const mark = comparison?.get(entry.name)
              const isSelected = selection.has(entry.name)
              return (
                <div
                  key={entry.name}
                  role="row"
                  aria-selected={isSelected}
                  className={`row${isSelected ? ' selected' : ''}${mark ? ` cmp-${mark}` : ''}${dropTarget === entry.name ? ' drop' : ''}`}
                  draggable
                  onDragStart={(e) => dragStart(e, entry)}
                  onMouseDown={(e) => click(e, index)}
                  onDoubleClick={() => props.onOpen(entry)}
                  onDragOver={(e) => {
                    if (!entry.isDirectory || !accepts(e)) return
                    e.preventDefault()
                    e.stopPropagation()
                    if (dropTarget !== entry.name) setDropTarget(entry.name)
                  }}
                  onDrop={entry.isDirectory ? (e) => drop(e, entry.name) : undefined}
                >
                  <div className="cell name">
                    <FileIcon name={entry.name} isDirectory={entry.isDirectory} isLink={entry.isLink} />
                    <span>{entry.name}</span>
                  </div>
                  <div className="cell size">{entry.isDirectory ? '' : formatSize(entry.size)}</div>
                  <div className="cell type">{fileType(entry.name, entry.isDirectory)}</div>
                  <div className="cell modified">{formatDate(entry.modified)}</div>
                  <div className="cell perms mono">{entry.permissions}</div>
                  {props.showOwner && <div className="cell owner">{entry.owner ? `${entry.owner} ${entry.group}` : ''}</div>}
                </div>
              )
            })}
            <div style={{ height: virtual.padBottom }} />
          </div>
          <div className="pane-footer">
            {selected.length
              ? `${selected.length} selected · ${formatSize(selected.reduce((n, e) => n + (e.size ?? 0), 0))}`
              : `${rows.filter((r) => !r.isDirectory).length} files, ${rows.filter((r) => r.isDirectory).length} folders · ${formatSize(rows.reduce((n, e) => n + (e.size ?? 0), 0))}`}
          </div>
        </div>
      )}
      {menu && <ContextMenu x={menu.x} y={menu.y} items={props.menu(selected)} onClose={() => setMenu(null)} />}
    </section>
  )
}

function PathBar(props: { icon: LucideIcon; title: string; path: string; disabled: boolean; onSubmit: (p: string) => void }) {
  const [text, setText] = useState(props.path)
  useEffect(() => setText(props.path), [props.path])
  const Icon = props.icon
  return (
    <form
      className="path-bar"
      onSubmit={(e) => {
        e.preventDefault()
        props.onSubmit(text.trim())
      }}
    >
      <Icon size={16} />
      <span className="pane-title">{props.title}</span>
      <input value={text} onChange={(e) => setText(e.target.value)} disabled={props.disabled} spellCheck={false} aria-label={`${props.title} path`} />
    </form>
  )
}

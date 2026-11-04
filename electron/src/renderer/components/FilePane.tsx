import { useEffect, useLayoutEffect, useMemo, useRef, useState, type DragEvent, type KeyboardEvent, type MouseEvent, type ReactNode } from 'react'
import { ArrowDown, ArrowUp, CornerLeftUp, RefreshCw, Search, X, type LucideIcon } from 'lucide-react'
import type { FileEntry } from '../../shared/types'
import { fileType, formatDate, formatSize } from '../../shared/util'
import { api } from '../api'
import { FileIcon } from './FileIcon'
import { ContextMenu, IconButton, useVirtualRows, type MenuEntry } from './ui'

export type Side = 'local' | 'remote'
export type CompareMark = 'lonely' | 'different' | 'newer'

const compareText: Record<CompareMark, string> = {
  lonely: 'Only in this pane',
  different: 'Size differs from the other pane',
  newer: 'Newer than in the other pane',
}
export interface DragPayload {
  side: Side
  dir: string
  entries: FileEntry[]
}

type SortKey = 'name' | 'size' | 'type' | 'modified' | 'permissions' | 'owner'
/** Row height in px; must match `.row` in styles.css. */
const ROW = 28
export const DRAG_TYPE = 'application/x-remotessh'
/**
 * Marks which pane a drag came from. Drag data can only be read on drop, but the list of types is readable
 * while dragging, so drop targets use this to accept drags from the other side only.
 */
export const dragSideType = (side: Side) => `${DRAG_TYPE}-${side}`

const isMac = api.platform === 'darwin'
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
  /** Resolves to false when the folder could not be opened. */
  onNavigate: (path: string) => Promise<boolean>
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
  /** Shift-click / Shift-arrow ranges start here (a name, so it survives sorting and refreshes). */
  const anchor = useRef<string | null>(null)
  /** The row the arrow keys move from. */
  const cursor = useRef<string | null>(null)
  /** A plain click on a row of a multiple selection selects just that row, but only once it is clear no drag started. */
  const collapseTo = useRef<string | null>(null)

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

  const totals = useMemo(() => {
    let files = 0
    let bytes = 0
    for (const r of rows) {
      if (!r.isDirectory) files++
      bytes += r.size ?? 0
    }
    return { files, folders: rows.length - files, bytes }
  }, [rows])

  const selected = useMemo(() => rows.filter((r) => selection.has(r.name)), [rows, selection])
  const virtual = useVirtualRows(rows.length, ROW)

  // A new folder starts at the top, unfiltered, with no range anchor.
  useLayoutEffect(() => {
    anchor.current = null
    cursor.current = null
    if (virtual.ref.current) virtual.ref.current.scrollTop = 0
  }, [props.path, virtual.ref])
  useEffect(() => setFilter(''), [props.path])

  const indexOf = (name: string | null) => (name == null ? -1 : rows.findIndex((r) => r.name === name))

  function selectRange(from: number, to: number, add: boolean) {
    const next = new Set(add ? selection : [])
    for (let i = Math.min(from, to); i <= Math.max(from, to); i++) next.add(rows[i].name)
    onSelection(next)
  }

  function scrollToRow(index: number) {
    const el = virtual.ref.current
    if (!el) return
    const top = index * ROW
    if (top < el.scrollTop) el.scrollTop = top
    else if (top + ROW > el.scrollTop + el.clientHeight) el.scrollTop = top + ROW - el.clientHeight
  }

  function mouseDown(e: MouseEvent, index: number) {
    const name = rows[index].name
    collapseTo.current = null
    // On macOS, Control-click is a right click.
    const contextClick = e.button === 2 || (isMac && e.ctrlKey)
    const additive = isMac ? e.metaKey : e.ctrlKey
    if (e.shiftKey && !contextClick) {
      const from = indexOf(anchor.current)
      if (from >= 0) {
        cursor.current = name
        return selectRange(from, index, additive)
      }
    }
    anchor.current = name
    cursor.current = name
    if (additive && !contextClick) {
      const next = new Set(selection)
      if (next.has(name)) next.delete(name)
      else next.add(name)
      onSelection(next)
    } else if (!selection.has(name)) {
      onSelection(new Set([name]))
    } else if (!contextClick && selection.size > 1) {
      collapseTo.current = name
    }
  }

  function rowClick(e: MouseEvent, name: string) {
    if (collapseTo.current === name && !e.shiftKey) onSelection(new Set([name]))
    collapseTo.current = null
  }

  function onKeyDown(e: KeyboardEvent) {
    if (e.target !== e.currentTarget) return
    const mod = e.ctrlKey || e.metaKey
    const page = Math.max(1, Math.floor((virtual.ref.current?.clientHeight ?? 0) / ROW) - 1)
    const current = indexOf(cursor.current ?? selected.at(-1)?.name ?? null)
    let target: number | null = null
    switch (e.key) {
      case 'ArrowDown': target = current + 1; break
      case 'ArrowUp': target = current < 0 ? 0 : current - 1; break
      case 'PageDown': target = current + page; break
      case 'PageUp': target = current - page; break
      case 'Home': target = 0; break
      case 'End': target = rows.length - 1; break
      case 'Enter':
        if (selected.length === 1) props.onOpen(selected[0])
        return
      case 'Backspace':
        // Cmd+Backspace is "move to trash" on macOS, which has no Delete key.
        if (mod && selected.length) props.onDelete(selected)
        else if (!mod && props.canGoUp) props.onUp()
        return
      case 'Delete':
        if (selected.length) props.onDelete(selected)
        return
      case 'F2':
        if (selected.length === 1) props.onRename(selected[0])
        return
      case 'a':
      case 'A':
        if (!mod) return
        e.preventDefault()
        onSelection(new Set(rows.map((r) => r.name)))
        return
      default:
        return
    }
    e.preventDefault()
    if (!rows.length) return
    const next = Math.max(0, Math.min(rows.length - 1, target))
    const name = rows[next].name
    if (e.shiftKey) {
      const from = indexOf(anchor.current)
      if (from < 0) anchor.current = cursor.current ?? name
      selectRange(from < 0 ? Math.max(0, current) : from, next, false)
    } else {
      anchor.current = name
      onSelection(new Set([name]))
    }
    cursor.current = name
    scrollToRow(next)
  }

  function dragStart(e: DragEvent, entry: FileEntry) {
    const dragged = selection.has(entry.name) ? selected : [entry]
    if (!selection.has(entry.name)) onSelection(new Set([entry.name]))
    collapseTo.current = null
    const payload: DragPayload = { side: props.side, dir: props.path, entries: dragged }
    e.dataTransfer.setData(DRAG_TYPE, JSON.stringify(payload))
    e.dataTransfer.setData(dragSideType(props.side), '1')
    e.dataTransfer.effectAllowed = 'copy'
  }

  function accepts(e: DragEvent): boolean {
    if (props.placeholder) return false
    const types = e.dataTransfer.types
    if (types.includes(dragSideType(props.side === 'local' ? 'remote' : 'local'))) return true
    return props.side === 'remote' && types.includes('Files')
  }

  /** The folder row under the pointer, or '' for the pane itself. */
  const dropDirAt = (e: DragEvent) => (e.target as HTMLElement).closest<HTMLElement>('[data-dir]')?.dataset.dir ?? ''

  function drop(e: DragEvent) {
    e.preventDefault()
    setDropTarget(null)
    if (!accepts(e)) return
    const targetDir = dropDirAt(e) || null
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
    <div
      className={`cell ${cls}`}
      role="columnheader"
      aria-sort={sort.key === k ? (sort.asc ? 'ascending' : 'descending') : 'none'}
      title={`Sort by ${label.toLowerCase()}`}
      onClick={() => setSort((s) => ({ key: k, asc: s.key === k ? !s.asc : true }))}
    >
      {label}
      {sort.key === k && (sort.asc ? <ArrowUp size={12} aria-hidden /> : <ArrowDown size={12} aria-hidden />)}
    </div>
  )

  return (
    <section className={`pane pane-${props.side}`} aria-label={`${props.title} files`}>
      <div className="pane-head">
        <span className="pane-title">
          <props.icon size={15} />
          {props.title}
        </span>
        <IconButton icon={CornerLeftUp} label="Parent directory" onClick={props.onUp} disabled={!props.canGoUp || !!props.placeholder} />
        <IconButton icon={RefreshCw} label="Refresh" onClick={props.onRefresh} disabled={!!props.placeholder} />
        <PathBar title={props.title} path={props.path} disabled={!!props.placeholder} onSubmit={props.onNavigate} />
        <label className="filter">
          <Search size={14} aria-hidden />
          <input
            value={filter}
            placeholder="Filter"
            aria-label={`Filter ${props.title.toLowerCase()} files by name`}
            spellCheck={false}
            onChange={(e) => setFilter(e.target.value)}
            onKeyDown={(e) => e.key === 'Escape' && filter && (e.stopPropagation(), setFilter(''))}
            disabled={!!props.placeholder}
          />
          {filter && (
            <button type="button" onClick={() => setFilter('')} aria-label="Clear filter" title="Clear filter">
              <X size={12} />
            </button>
          )}
        </label>
      </div>
      {props.placeholder ? (
        <div className="pane-placeholder">{props.placeholder}</div>
      ) : (
        <div
          className={`table${props.showOwner ? ' with-owner' : ''}`}
          role="grid"
          aria-label={`${props.title} files`}
          aria-multiselectable
          aria-rowcount={rows.length + 1}
          aria-busy={props.loading || undefined}
        >
          <div className="row header" role="row" aria-rowindex={1}>
            {header('Name', 'name', 'name')}
            {header('Size', 'size', 'size')}
            {header('Type', 'type', 'type')}
            {header('Modified', 'modified', 'modified')}
            {header('Permissions', 'permissions', 'perms')}
            {props.showOwner && header('Owner/Group', 'owner', 'owner')}
          </div>
          <div
            className={`rows${dropTarget === '' ? ' drop' : ''}${props.loading ? ' loading' : ''}`}
            ref={virtual.setRef}
            role="rowgroup"
            tabIndex={0}
            onKeyDown={onKeyDown}
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
              const target = dropDirAt(e)
              if (target !== dropTarget) setDropTarget(target)
            }}
            onDragLeave={(e) => !e.currentTarget.contains(e.relatedTarget as Node | null) && setDropTarget(null)}
            onDrop={drop}
          >
            {rows.length === 0 && !props.loading && (
              <div className="empty small">{filter ? `No names contain “${filter}”.` : entries.length ? 'Only hidden files are in this folder.' : 'This folder is empty.'}</div>
            )}
            <div style={{ height: virtual.padTop }} />
            {rows.slice(virtual.start, virtual.end).map((entry, i) => {
              const index = virtual.start + i
              const mark = comparison?.get(entry.name)
              const isSelected = selection.has(entry.name)
              return (
                <div
                  key={entry.name}
                  role="row"
                  aria-rowindex={index + 2}
                  aria-selected={isSelected}
                  data-dir={entry.isDirectory ? entry.name : undefined}
                  title={mark && compareText[mark]}
                  className={`row${isSelected ? ' selected' : ''}${mark ? ` cmp-${mark}` : ''}${dropTarget === entry.name ? ' drop' : ''}`}
                  draggable
                  onDragStart={(e) => dragStart(e, entry)}
                  onMouseDown={(e) => mouseDown(e, index)}
                  onClick={(e) => rowClick(e, entry.name)}
                  onDoubleClick={() => props.onOpen(entry)}
                >
                  <div className="cell name" role="gridcell">
                    <FileIcon name={entry.name} isDirectory={entry.isDirectory} isLink={entry.isLink} />
                    <span>{entry.name}</span>
                  </div>
                  <div className="cell size" role="gridcell">{entry.isDirectory ? '' : formatSize(entry.size)}</div>
                  <div className="cell type" role="gridcell">{fileType(entry.name, entry.isDirectory)}</div>
                  <div className="cell modified" role="gridcell">{formatDate(entry.modified)}</div>
                  <div className="cell perms mono" role="gridcell">{entry.permissions}</div>
                  {props.showOwner && <div className="cell owner" role="gridcell">{entry.owner ? `${entry.owner} ${entry.group}` : ''}</div>}
                </div>
              )
            })}
            <div style={{ height: virtual.padBottom }} />
          </div>
          <div className="pane-footer">
            {selected.length
              ? `${selected.length} selected · ${formatSize(selected.reduce((n, e) => n + (e.size ?? 0), 0))}`
              : `${totals.files} ${totals.files === 1 ? 'file' : 'files'}, ${totals.folders} ${totals.folders === 1 ? 'folder' : 'folders'} · ${formatSize(totals.bytes)}`}
          </div>
        </div>
      )}
      {menu && <ContextMenu x={menu.x} y={menu.y} items={props.menu(selected)} onClose={() => setMenu(null)} />}
    </section>
  )
}

function PathBar(props: { title: string; path: string; disabled: boolean; onSubmit: (p: string) => Promise<boolean> }) {
  const [text, setText] = useState(props.path)
  useEffect(() => setText(props.path), [props.path])
  return (
    <form
      className="path-bar"
      onSubmit={(e) => {
        e.preventDefault()
        const path = props.path
        // A folder that cannot be opened leaves the pane where it was, so the field goes back too.
        void props.onSubmit(text.trim()).then((ok) => !ok && setText(path))
      }}
    >
      <input
        value={text}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => e.key === 'Escape' && text !== props.path && (e.stopPropagation(), setText(props.path))}
        disabled={props.disabled}
        spellCheck={false}
        aria-label={`${props.title} path`}
      />
    </form>
  )
}

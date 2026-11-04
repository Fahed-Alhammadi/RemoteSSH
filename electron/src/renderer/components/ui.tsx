import { useCallback, useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type ReactNode, type RefObject } from 'react'
import type { LucideIcon } from 'lucide-react'
import { X } from 'lucide-react'

export function IconButton(props: {
  icon: LucideIcon
  label: string
  onClick?: () => void
  disabled?: boolean
  active?: boolean
  tint?: string
  shortcut?: string
}) {
  const { icon: Icon, label, onClick, disabled, active, tint, shortcut } = props
  return (
    <button
      type="button"
      className={`icon-button${active ? ' active' : ''}`}
      onClick={onClick}
      disabled={disabled}
      title={shortcut ? `${label} (${shortcut})` : label}
      aria-label={label}
      aria-pressed={active}
    >
      <Icon size={18} color={disabled ? undefined : tint} />
    </button>
  )
}

// MARK: Layers (modals and menus)

const focusable = 'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])'

interface Layer {
  el: RefObject<HTMLElement | null>
  escape: () => void
}

/** Open modals and menus, topmost last. Only the topmost one gets Escape and keeps Tab focus inside. */
const layers: Layer[] = []

function onLayerKey(e: KeyboardEvent) {
  const top = layers.at(-1)
  const el = top?.el.current
  if (!top || !el) return
  if (e.key === 'Escape') {
    e.preventDefault()
    e.stopPropagation()
    top.escape()
  } else if (e.key === 'Tab') {
    const items = [...el.querySelectorAll<HTMLElement>(focusable)].filter((i) => i.offsetParent !== null)
    if (!items.length) return e.preventDefault()
    const first = items[0]
    const last = items[items.length - 1]
    const active = document.activeElement
    if (!el.contains(active) || (e.shiftKey && (active === first || active === el)) || (!e.shiftKey && active === last)) {
      e.preventDefault()
      ;(e.shiftKey ? last : first).focus()
    }
  }
}

/**
 * Registers a modal layer: Escape calls `onEscape`, Tab stays inside, and focus returns to where it was on close
 * (unless something else, such as the next dialog, has taken it). Returns a function that restores focus early.
 */
function useLayer(el: RefObject<HTMLElement | null>, onEscape: (() => void) | undefined) {
  const escape = useRef(onEscape)
  escape.current = onEscape
  // Read during render, before autoFocus moves focus into the layer.
  const [previous] = useState(() => document.activeElement)
  // The element autoFocus picked, kept so a re-run of the effect (StrictMode) can go back to it.
  const initial = useRef<HTMLElement | null>(null)
  const restore = useCallback(() => {
    if (previous instanceof HTMLElement && previous.isConnected) previous.focus()
  }, [previous])
  useEffect(() => {
    const layer: Layer = { el, escape: () => escape.current?.() }
    layers.push(layer)
    if (layers.length === 1) window.addEventListener('keydown', onLayerKey, true)
    const own = el.current
    const active = document.activeElement
    if (own?.contains(active) && active instanceof HTMLElement) initial.current ??= active
    else if (own) (initial.current?.isConnected ? initial.current : own).focus()
    return () => {
      layers.splice(layers.indexOf(layer), 1)
      if (!layers.length) window.removeEventListener('keydown', onLayerKey, true)
      const now = document.activeElement
      if (!now || now === document.body || own?.contains(now)) restore()
    }
  }, [el, restore])
  return restore
}

export function Modal(props: {
  title: string
  icon?: LucideIcon
  onClose?: () => void
  /** Clicking outside closes the dialog; off for dialogs with edits that would be lost. */
  closeOnBackdrop?: boolean
  children: ReactNode
  footer?: ReactNode
  width?: number
}) {
  const { title, icon: Icon, onClose, closeOnBackdrop = true, children, footer, width } = props
  const ref = useRef<HTMLDivElement>(null)
  useLayer(ref, onClose)
  return (
    <div className="modal-backdrop" onMouseDown={(e) => closeOnBackdrop && e.target === e.currentTarget && onClose?.()}>
      <div className="modal" ref={ref} tabIndex={-1} style={{ width }} role="dialog" aria-modal="true" aria-label={title}>
        <header>
          {Icon && <Icon size={18} />}
          <h2>{title}</h2>
          {onClose && (
            <button type="button" className="icon-button small" onClick={onClose} aria-label="Close" title="Close">
              <X size={16} />
            </button>
          )}
        </header>
        <div className="modal-body">{children}</div>
        {footer && <footer>{footer}</footer>}
      </div>
    </div>
  )
}

export interface MenuItem {
  label: string
  icon?: LucideIcon
  onClick: () => void
  disabled?: boolean
  danger?: boolean
}
export type MenuEntry = MenuItem | 'separator'

export function ContextMenu(props: { x: number; y: number; items: MenuEntry[]; onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null)
  const [pos, setPos] = useState({ x: props.x, y: props.y })
  const onClose = useRef(props.onClose)
  onClose.current = props.onClose
  const restoreFocus = useLayer(ref, props.onClose)
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    const { innerWidth, innerHeight } = window
    setPos({
      x: Math.max(4, Math.min(props.x, innerWidth - el.offsetWidth - 4)),
      y: Math.max(4, Math.min(props.y, innerHeight - el.offsetHeight - 4)),
    })
    el.querySelector<HTMLElement>('[role="menuitem"]:not([disabled])')?.focus()
  }, [props.x, props.y])
  useEffect(() => {
    const close = () => onClose.current()
    window.addEventListener('blur', close)
    window.addEventListener('resize', close)
    return () => {
      window.removeEventListener('blur', close)
      window.removeEventListener('resize', close)
    }
  }, [])
  const onKeyDown = (e: ReactKeyboardEvent) => {
    const items = [...(ref.current?.querySelectorAll<HTMLElement>('[role="menuitem"]:not([disabled])') ?? [])]
    if (!items.length) return
    const i = items.indexOf(document.activeElement as HTMLElement)
    const go = (n: number) => (e.preventDefault(), items[(n + items.length) % items.length].focus())
    if (e.key === 'ArrowDown') go(i + 1)
    else if (e.key === 'ArrowUp') go(i < 0 ? -1 : i - 1)
    else if (e.key === 'Home') go(0)
    else if (e.key === 'End') go(-1)
  }
  return (
    <div className="menu-backdrop" onMouseDown={props.onClose} onContextMenu={(e) => (e.preventDefault(), props.onClose())}>
      <div className="context-menu" ref={ref} role="menu" tabIndex={-1} style={{ left: pos.x, top: pos.y }} onMouseDown={(e) => e.stopPropagation()} onKeyDown={onKeyDown}>
        {props.items.map((item, i) =>
          item === 'separator' ? (
            <div key={i} className="separator" role="separator" />
          ) : (
            <button
              key={i}
              type="button"
              role="menuitem"
              disabled={item.disabled}
              className={item.danger ? 'danger' : undefined}
              onClick={() => {
                // Hand focus back first, so a dialog the item opens returns focus there too.
                restoreFocus()
                props.onClose()
                item.onClick()
              }}
            >
              {item.icon ? <item.icon size={15} /> : <span style={{ width: 15 }} />}
              {item.label}
            </button>
          ),
        )}
      </div>
    </div>
  )
}

/**
 * Renders only the rows in view; rows have a fixed height (keep it equal to the CSS row height).
 * Attach `setRef` to the scrolling element; it may mount after the hook (e.g. behind a placeholder).
 */
export function useVirtualRows(count: number, rowHeight: number) {
  const ref = useRef<HTMLDivElement | null>(null)
  const [el, setEl] = useState<HTMLDivElement | null>(null)
  const setRef = useCallback((node: HTMLDivElement | null) => {
    ref.current = node
    setEl(node)
  }, [])
  const [view, setView] = useState({ top: 0, height: 600 })
  useLayoutEffect(() => {
    if (!el) return
    // Only re-render when the first visible row or the height changes, not on every scrolled pixel.
    const update = () => {
      const top = Math.floor(el.scrollTop / rowHeight) * rowHeight
      const height = el.clientHeight
      setView((v) => (v.top === top && v.height === height ? v : { top, height }))
    }
    update()
    const ro = new ResizeObserver(update)
    ro.observe(el)
    el.addEventListener('scroll', update, { passive: true })
    return () => {
      ro.disconnect()
      el.removeEventListener('scroll', update)
    }
  }, [el, rowHeight])
  const overscan = 8
  const start = Math.max(0, Math.min(count, Math.floor(view.top / rowHeight) - overscan))
  const end = Math.max(start, Math.min(count, Math.ceil((view.top + view.height) / rowHeight) + overscan))
  return { ref, setRef, start, end, padTop: start * rowHeight, padBottom: (count - end) * rowHeight }
}

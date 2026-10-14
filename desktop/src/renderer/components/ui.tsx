import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
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
      <Icon size={18} strokeWidth={1.8} color={disabled ? undefined : tint} />
    </button>
  )
}

export function Modal(props: {
  title: string
  icon?: LucideIcon
  onClose?: () => void
  children: ReactNode
  footer?: ReactNode
  width?: number
}) {
  const { title, icon: Icon, onClose, children, footer, width } = props
  useEffect(() => {
    if (!onClose) return
    const key = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', key)
    return () => window.removeEventListener('keydown', key)
  }, [onClose])
  return (
    <div className="modal-backdrop" onMouseDown={(e) => e.target === e.currentTarget && onClose?.()}>
      <div className="modal" style={{ width }} role="dialog" aria-modal="true" aria-label={title}>
        <header>
          {Icon && <Icon size={18} />}
          <h2>{title}</h2>
          {onClose && (
            <button type="button" className="icon-button small" onClick={onClose} aria-label="Close">
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
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    const { innerWidth, innerHeight } = window
    setPos({
      x: Math.min(props.x, innerWidth - el.offsetWidth - 4),
      y: Math.min(props.y, innerHeight - el.offsetHeight - 4),
    })
  }, [props.x, props.y])
  useEffect(() => {
    const close = () => props.onClose()
    window.addEventListener('blur', close)
    window.addEventListener('resize', close)
    return () => {
      window.removeEventListener('blur', close)
      window.removeEventListener('resize', close)
    }
  }, [props])
  return (
    <div className="menu-backdrop" onMouseDown={props.onClose} onContextMenu={(e) => (e.preventDefault(), props.onClose())}>
      <div className="context-menu" ref={ref} style={{ left: pos.x, top: pos.y }} onMouseDown={(e) => e.stopPropagation()}>
        {props.items.map((item, i) =>
          item === 'separator' ? (
            <div key={i} className="separator" />
          ) : (
            <button
              key={i}
              type="button"
              disabled={item.disabled}
              className={item.danger ? 'danger' : undefined}
              onClick={() => {
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

/** Renders only the rows in view; rows have a fixed height. */
export function useVirtualRows(count: number, rowHeight: number) {
  const ref = useRef<HTMLDivElement>(null)
  const [view, setView] = useState({ top: 0, height: 600 })
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    const update = () => setView({ top: el.scrollTop, height: el.clientHeight })
    update()
    const ro = new ResizeObserver(update)
    ro.observe(el)
    el.addEventListener('scroll', update, { passive: true })
    return () => {
      ro.disconnect()
      el.removeEventListener('scroll', update)
    }
  }, [])
  const overscan = 8
  const start = Math.max(0, Math.floor(view.top / rowHeight) - overscan)
  const end = Math.min(count, Math.ceil((view.top + view.height) / rowHeight) + overscan)
  return { ref, start, end, padTop: start * rowHeight, padBottom: (count - end) * rowHeight }
}

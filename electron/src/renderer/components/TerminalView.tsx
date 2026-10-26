import { useEffect, useRef, useState } from 'react'
import { FitAddon } from '@xterm/addon-fit'
import { Terminal, type ITheme } from '@xterm/xterm'
import '@xterm/xterm/css/xterm.css'
import { ClipboardPaste, Copy, Eraser, TextSelect } from 'lucide-react'
import type { TerminalEvent } from '../../shared/api'
import { errorMessage, RemotePath, shellQuote } from '../../shared/util'
import { api } from '../api'
import { DRAG_TYPE, type DragPayload } from './FilePane'
import { ContextMenu } from './ui'

export type TerminalStatus = 'connecting' | 'connected' | 'disconnected'

/** A shell to show: a new `key` starts it; with `reuse`, a running shell just changes to `dir` instead. */
export interface TerminalRequest {
  key: number
  dir: string | null
  reuse: boolean
}

const isMac = api.platform === 'darwin'

/** Terminal colours come from the --term-* tokens in styles.css (ink in both themes). */
function readTheme(): ITheme {
  const css = getComputedStyle(document.documentElement)
  const v = (name: string) => css.getPropertyValue(`--term-${name}`).trim()
  const ansi = {
    black: v('black'),
    red: v('red'),
    green: v('green'),
    yellow: v('yellow'),
    blue: v('blue'),
    magenta: v('magenta'),
    cyan: v('cyan'),
    white: v('white'),
  }
  return {
    background: v('bg'),
    foreground: v('fg'),
    cursor: v('cursor'),
    cursorAccent: v('bg'),
    selectionBackground: v('selection'),
    ...ansi,
    brightBlack: v('bright-black'),
    brightRed: ansi.red,
    brightGreen: ansi.green,
    brightYellow: ansi.yellow,
    brightBlue: ansi.blue,
    brightMagenta: ansi.magenta,
    brightCyan: ansi.cyan,
    brightWhite: v('bright-white'),
  }
}

export function TerminalView(props: {
  request: TerminalRequest
  visible: boolean
  onStatus: (status: TerminalStatus) => void
}) {
  const host = useRef<HTMLDivElement>(null)
  const term = useRef<{ xterm: Terminal; fit: FitAddon; show: (e: TerminalEvent) => void } | null>(null)
  const shellID = useRef<number | null>(null)
  /** Output for shells whose id the renderer has not received yet. */
  const early = useRef(new Map<number, TerminalEvent[]>())
  const onStatus = useRef(props.onStatus)
  onStatus.current = props.onStatus
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null)

  const copy = () => {
    const text = term.current?.xterm.getSelection()
    if (text) void navigator.clipboard.writeText(text)
  }
  const paste = () => void navigator.clipboard.readText().then((text) => text && term.current?.xterm.paste(text))

  // Create the terminal once.
  useEffect(() => {
    const xterm = new Terminal({
      fontFamily: getComputedStyle(document.documentElement).getPropertyValue('--mono'),
      fontSize: 13,
      cursorBlink: true,
      scrollback: 5000,
      theme: readTheme(),
    })
    const fit = new FitAddon()
    xterm.loadAddon(fit)
    xterm.open(host.current!)

    // Ctrl+C stays "interrupt"; on Windows/Linux copy and paste are Ctrl+Shift+C/V like other terminals.
    xterm.attachCustomKeyEventHandler((e) => {
      if (e.type !== 'keydown') return true
      if (e.ctrlKey && e.code === 'Backquote') return false // App handles Ctrl+` (show/hide the terminal).
      if (!isMac && e.ctrlKey && e.shiftKey && (e.code === 'KeyC' || e.code === 'KeyV')) {
        e.preventDefault()
        if (e.code === 'KeyC') copy()
        else paste()
        return false
      }
      return true
    })
    const subs = [
      xterm.onData((data) => shellID.current != null && void api.terminalInput(shellID.current, data)),
      xterm.onResize(({ cols, rows }) => shellID.current != null && void api.terminalResize(shellID.current, cols, rows)),
    ]
    const show = (e: TerminalEvent) => {
      if (e.data) xterm.write(e.data)
      if (e.ended) {
        xterm.write(`\r\n\x1b[2m[Session ended: ${e.ended}]\x1b[0m\r\n`)
        shellID.current = null
        onStatus.current('disconnected')
      }
    }
    term.current = { xterm, fit, show }
    const offTerminal = api.onTerminal((events) => {
      for (const e of events) {
        if (e.id === shellID.current) show(e)
        else early.current.set(e.id, [...(early.current.get(e.id) ?? []), e])
      }
    })

    const resize = new ResizeObserver(() => host.current?.offsetWidth && fit.fit())
    resize.observe(host.current!)

    return () => {
      resize.disconnect()
      offTerminal()
      subs.forEach((s) => s.dispose())
      if (shellID.current != null) void api.terminalClose(shellID.current)
      shellID.current = null
      xterm.dispose()
      term.current = null
    }
  }, [])

  // Start a shell for each new request (or cd in the running one).
  const { key, dir, reuse } = props.request
  useEffect(() => {
    const t = term.current
    if (!t) return
    const { xterm, fit, show } = t
    if (reuse && shellID.current != null && dir) {
      void api.terminalInput(shellID.current, ` cd -- ${shellQuote(dir)}\r`)
      xterm.focus()
      return
    }
    if (shellID.current != null) void api.terminalClose(shellID.current)
    shellID.current = null
    let cancelled = false
    xterm.reset()
    fit.fit()
    onStatus.current('connecting')
    api.terminalOpen(xterm.cols, xterm.rows, dir).then(
      (id) => {
        if (cancelled) return void api.terminalClose(id)
        shellID.current = id
        onStatus.current('connected')
        for (const e of early.current.get(id) ?? []) show(e)
        early.current.clear()
        xterm.focus()
      },
      (e) => {
        if (cancelled) return
        xterm.write(`\x1b[31m${errorMessage(e)}\x1b[0m\r\n`)
        onStatus.current('disconnected')
      },
    )
    return () => {
      cancelled = true
    }
  }, [key])

  useEffect(() => {
    if (!props.visible || !term.current) return
    term.current.fit.fit()
    term.current.xterm.focus()
  }, [props.visible])

  // Remote files dropped from the remote pane are typed as quoted paths.
  const onDrop = (e: React.DragEvent) => {
    const raw = e.dataTransfer.getData(DRAG_TYPE)
    if (!raw) return
    e.preventDefault()
    const payload = JSON.parse(raw) as DragPayload
    if (payload.side !== 'remote') return
    term.current?.xterm.paste(payload.entries.map((f) => shellQuote(RemotePath.join(payload.dir, f.name))).join(' ') + ' ')
    term.current?.xterm.focus()
  }

  return (
    <div
      className="term-panel"
      hidden={!props.visible}
      onContextMenu={(e) => {
        e.preventDefault()
        setMenu({ x: e.clientX, y: e.clientY })
      }}
      onDragOver={(e) => e.dataTransfer.types.includes(DRAG_TYPE) && e.preventDefault()}
      onDrop={onDrop}
    >
      <div className="term-host" ref={host} />
      {menu && (
        <ContextMenu
          x={menu.x}
          y={menu.y}
          onClose={() => setMenu(null)}
          items={[
            { label: 'Copy', icon: Copy, disabled: !term.current?.xterm.hasSelection(), onClick: copy },
            { label: 'Paste', icon: ClipboardPaste, onClick: paste },
            'separator',
            { label: 'Select All', icon: TextSelect, onClick: () => term.current?.xterm.selectAll() },
            { label: 'Clear', icon: Eraser, onClick: () => term.current?.xterm.clear() },
          ]}
        />
      )}
    </div>
  )
}

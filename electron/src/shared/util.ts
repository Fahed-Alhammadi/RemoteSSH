// Small helpers shared by the main process and the renderer.

/** Remote paths are absolute POSIX strings. */
export const RemotePath = {
  join(base: string, name: string): string {
    if (name.startsWith('/')) return name
    return base.endsWith('/') ? base + name : `${base}/${name}`
  },
  parent(path: string): string {
    const trimmed = path.replace(/(.)\/+$/, '$1')
    const idx = trimmed.lastIndexOf('/')
    return idx <= 0 ? '/' : trimmed.slice(0, idx)
  },
  lastComponent(path: string): string {
    const parts = path.split('/').filter(Boolean)
    return parts.length ? parts[parts.length - 1] : '/'
  },
  normalize(path: string): string {
    const parts: string[] = []
    for (const part of path.split('/')) {
      if (!part || part === '.') continue
      if (part === '..') parts.pop()
      else parts.push(part)
    }
    return `/${parts.join('/')}`
  },
}

export const Permissions = {
  symbolic(mode: number): string {
    const type = (mode & 0o170000) === 0o040000 ? 'd' : (mode & 0o170000) === 0o120000 ? 'l' : '-'
    let out = type
    for (let shift = 6; shift >= 0; shift -= 3) {
      const bits = (mode >> shift) & 0o7
      out += (bits & 4 ? 'r' : '-') + (bits & 2 ? 'w' : '-') + (bits & 1 ? 'x' : '-')
    }
    return out
  },
  bits(text: string): number | null {
    if ((text.length === 3 || text.length === 4) && /^[0-7]+$/.test(text)) return parseInt(text, 8) & 0o777
    if (text.length < 10) return null
    let mode = 0
    for (let i = 1; i <= 9; i++) {
      const c = text[i]
      if (c !== '-' && c !== 'S' && c !== 'T') mode |= 1 << (9 - i)
    }
    return mode
  },
  octal(bits: number): string {
    return (bits & 0o777).toString(8).padStart(3, '0')
  },
}

const units = ['B', 'KB', 'MB', 'GB', 'TB']

export function formatSize(bytes: number | null | undefined): string {
  if (bytes == null) return ''
  if (bytes < 1024) return `${bytes} B`
  let value = bytes
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit++
  }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`
}

const dateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: 'short', timeStyle: 'short' })

export function formatDate(ms: number | null | undefined): string {
  return ms == null ? '' : dateFormat.format(ms)
}

export function fileType(name: string, isDirectory: boolean): string {
  if (isDirectory) return 'Directory'
  const dot = name.lastIndexOf('.')
  return dot > 0 ? `${name.slice(dot + 1).toUpperCase()}-file` : 'File'
}

export function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '')
  return String(error)
}

/** Compares dotted versions ("v1.2.10" > "1.2.9"); pre-release suffixes are ignored. */
export function compareVersions(a: string, b: string): number {
  const parts = (v: string) => v.replace(/^v/i, '').split(/[-+]/)[0].split('.').map((n) => parseInt(n, 10) || 0)
  const x = parts(a)
  const y = parts(b)
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0)
    if (d !== 0) return Math.sign(d)
  }
  return 0
}

/** Quotes a string as one POSIX shell word. */
export function shellQuote(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`
}

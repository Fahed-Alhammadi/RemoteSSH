import fs from 'node:fs'
import path from 'node:path'
import type { FileEntry, LocalListing } from '../../shared/types'
import { Permissions } from '../../shared/util'

const isWindows = process.platform === 'win32'

/** On Windows the empty path is a virtual "Computer" listing of drive letters. */
export async function listLocal(dir: string): Promise<LocalListing> {
  if (isWindows && dir === '') return { path: '', parent: null, entries: listDrives() }
  const resolved = path.resolve(dir)
  const dirents = await fs.promises.readdir(resolved, { withFileTypes: true })
  const entries = await Promise.all(
    dirents.map(async (d): Promise<FileEntry | null> => {
      const full = path.join(resolved, d.name)
      try {
        const lst = await fs.promises.lstat(full)
        const isLink = lst.isSymbolicLink()
        const st = isLink ? await fs.promises.stat(full).catch(() => lst) : lst
        return {
          name: d.name,
          isDirectory: st.isDirectory(),
          isLink,
          size: st.isDirectory() ? null : st.size,
          modified: st.mtimeMs,
          permissions: isWindows ? '' : Permissions.symbolic(lst.mode),
          owner: '',
          group: '',
        }
      } catch {
        return null // vanished or unreadable (e.g. locked system files)
      }
    }),
  )
  const parent = path.dirname(resolved)
  return {
    path: resolved,
    parent: parent !== resolved ? parent : isWindows ? '' : null,
    entries: entries.filter((e): e is FileEntry => e !== null),
  }
}

function listDrives(): FileEntry[] {
  const drives: FileEntry[] = []
  for (let c = 65; c <= 90; c++) {
    const root = `${String.fromCharCode(c)}:\\`
    if (fs.existsSync(root)) {
      drives.push({ name: root, isDirectory: true, isLink: false, size: null, modified: null, permissions: '', owner: '', group: '' })
    }
  }
  return drives
}

export function localStat(file: string): { size: number; modified: number; isDirectory: boolean } | null {
  try {
    const st = fs.statSync(file)
    return { size: st.size, modified: st.mtimeMs, isDirectory: st.isDirectory() }
  } catch {
    return null
  }
}

/**
 * `dir` joined with a file name that came from a server listing, or null when the name would leave `dir`
 * ("..", "../x", and on Windows "..\x" or "C:x"), so a hostile server can't make a download write elsewhere.
 */
export function localChild(dir: string, name: string, p: typeof path.posix = path): string | null {
  if (!name || name === '.' || name === '..' || name.includes('\0') || p.basename(name) !== name) return null
  return p.join(dir, name)
}

/** File types each OS runs (or installs) when opened with their default handler, instead of showing them. */
const PROGRAM_EXTENSIONS: Partial<Record<NodeJS.Platform, Set<string>>> = {
  win32: new Set([
    'exe', 'com', 'scr', 'pif', 'bat', 'cmd', 'msi', 'msp', 'msc', 'cpl', 'hta', 'js', 'jse', 'vbs', 'vbe', 'wsf',
    'wsh', 'ps1', 'reg', 'lnk', 'url', 'scf', 'inf', 'application', 'appref-ms', 'jar', 'appx', 'msix', 'settingcontent-ms',
  ]),
  darwin: new Set(['app', 'command', 'tool', 'terminal', 'workflow', 'action', 'pkg', 'mpkg', 'scpt', 'jar', 'fileloc', 'inetloc', 'webloc']),
  linux: new Set(['desktop', 'appimage', 'run', 'jar', 'deb', 'rpm']),
}

/** True when opening `name` with its default app would run it (View/Edit then only reveals the file). */
export function opensAsProgram(name: string, platform: NodeJS.Platform = process.platform): boolean {
  const dot = name.lastIndexOf('.')
  return dot >= 0 && (PROGRAM_EXTENSIONS[platform]?.has(name.slice(dot + 1).toLowerCase()) ?? false)
}

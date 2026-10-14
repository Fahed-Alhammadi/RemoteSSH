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

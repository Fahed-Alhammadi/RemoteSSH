import fs from 'node:fs'
import path from 'node:path'

export function readJSON<T>(file: string, fallback: T): T {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8')) as T
  } catch {
    return fallback
  }
}

/** Atomic write (temp file + rename), readable only by the current user. */
export function writeJSON(file: string, value: unknown): void {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2), { mode: 0o600 })
  fs.renameSync(tmp, file)
}

/** Like writeJSON, without blocking the main process and without indentation (for large, frequently saved files). */
export async function writeJSONAsync(file: string, value: unknown, stillWanted: () => boolean = () => true): Promise<void> {
  await fs.promises.mkdir(path.dirname(file), { recursive: true })
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`
  await fs.promises.writeFile(tmp, JSON.stringify(value), { mode: 0o600 })
  if (stillWanted()) await fs.promises.rename(tmp, file)
  else await fs.promises.rm(tmp, { force: true })
}

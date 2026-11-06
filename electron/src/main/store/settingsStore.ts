import path from 'node:path'
import { defaultSettings, type AppSettings, type TransferItem } from '../../shared/types'
import { readJSON, writeJSON, writeJSONAsync } from './jsonFile'

export class SettingsStore {
  private readonly file: string
  value: AppSettings

  constructor(dir: string) {
    this.file = path.join(dir, 'settings.json')
    this.value = { ...defaultSettings, ...readJSON<Partial<AppSettings>>(this.file, {}) }
  }

  save(value: AppSettings): void {
    this.value = { ...defaultSettings, ...value }
    writeJSON(this.file, this.value)
  }
}

/** Persists unfinished transfers so the queue survives a restart. */
export class QueueStore {
  private readonly file: string

  constructor(dir: string) {
    this.file = path.join(dir, 'queue.json')
  }

  load(): TransferItem[] {
    const items = readJSON<TransferItem[]>(this.file, [])
    return Array.isArray(items)
      ? items.map((i) => (i.status === 'transferring' ? { ...i, status: 'queued', speed: undefined } : i))
      : []
  }

  private pending: Promise<void> = Promise.resolve()
  /** Set by the final synchronous save; a background save still in flight must not replace it. */
  private final = false

  private static rows(items: TransferItem[]): Omit<TransferItem, 'speed'>[] {
    return items.filter((i) => i.status !== 'finished').map(({ speed: _speed, ...rest }) => rest)
  }

  /** Synchronous save (on quit). */
  save(items: TransferItem[]): void {
    this.final = true
    writeJSON(this.file, QueueStore.rows(items))
  }

  /** Background save while the queue runs; saves are chained so an older one never lands last. */
  saveAsync(items: TransferItem[]): Promise<void> {
    const rows = QueueStore.rows(items)
    this.pending = this.pending.then(() => writeJSONAsync(this.file, rows, () => !this.final)).catch(() => undefined)
    return this.pending
  }
}

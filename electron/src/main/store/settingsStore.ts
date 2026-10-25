import path from 'node:path'
import { defaultSettings, type AppSettings, type TransferItem } from '../../shared/types'
import { readJSON, writeJSON } from './jsonFile'

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

  save(items: TransferItem[]): void {
    writeJSON(this.file, items.filter((i) => i.status !== 'finished').map(({ speed: _speed, ...rest }) => rest))
  }
}

import fs from 'node:fs'
import path from 'node:path'
import { newID } from '../shared/site'
import type { AppSettings, FileEntry, OverwriteAction, Site, TransferDirection, TransferItem, TransferStatus } from '../shared/types'
import { errorMessage, RemotePath } from '../shared/util'
import { localStat } from './engine/localFS'
import { ask, CancelledError, type Prompter, type RemoteSession } from './engine/session'
import type { QueueStore } from './store/settingsStore'

export interface TransferHost {
  settings(): AppSettings
  site(id: string): Site | null
  connectSession(site: Site): Promise<RemoteSession>
  /** The connection used for browsing, if it belongs to `siteID` (used to expand folders). */
  browseSession(siteID: string): RemoteSession | null
  prompter: Prompter
  status(text: string): void
  error(text: string): void
  /** Batched queue changes for the UI. */
  publish(update: { upserts: TransferItem[]; removed: string[]; processing: boolean }): void
  transferFinished(item: TransferItem): void
}

/**
 * Runs the queue with up to `maxConcurrentTransfers` workers, each on its own pooled
 * connection. Unfinished items persist across restarts. UI updates are coalesced to 10 Hz,
 * so per-chunk progress never floods IPC.
 */
export class TransferManager {
  private items = new Map<string, TransferItem>()
  processing = true
  private aborts = new Map<string, AbortController>()
  private idle = new Map<string, RemoteSession[]>()
  private retries = new Map<string, number>()
  private overwriteForAll = new Map<TransferDirection, Exclude<OverwriteAction, 'ask'>>()
  private forceOverwrite = new Set<string>()
  private dirty = new Set<string>()
  private removed = new Set<string>()
  private flushTimer: NodeJS.Timeout | null = null
  private saveTimer: NodeJS.Timeout | null = null

  constructor(private readonly host: TransferHost, private readonly store: QueueStore) {
    for (const item of store.load()) this.items.set(item.id, item)
  }

  all(): TransferItem[] {
    return [...this.items.values()]
  }

  private get active(): number {
    let n = 0
    for (const i of this.items.values()) if (i.status === 'transferring') n++
    return n
  }

  // MARK: Enqueue

  async enqueueDownload(entries: FileEntry[], remoteDir: string, localDir: string, site: Site): Promise<void> {
    for (const entry of entries) {
      const remote = RemotePath.join(remoteDir, entry.name)
      const local = path.join(localDir, entry.name)
      if (entry.isDirectory) await this.expandRemote(remote, local, site)
      else this.add(this.make(site.id, 'download', local, remote, entry.size))
    }
    this.resume()
  }

  private async expandRemote(remote: string, local: string, site: Site): Promise<void> {
    const session = this.host.browseSession(site.id)
    if (!session) return
    try {
      fs.mkdirSync(local, { recursive: true })
      for (const child of await session.list(remote)) {
        const r = RemotePath.join(remote, child.name)
        const l = path.join(local, child.name)
        if (child.isDirectory) await this.expandRemote(r, l, site)
        else this.add(this.make(site.id, 'download', l, r, child.size))
      }
    } catch (e) {
      this.host.error(`Could not list ${remote}: ${errorMessage(e)}`)
    }
  }

  async enqueueUpload(localPaths: string[], remoteDir: string, site: Site): Promise<void> {
    for (const local of localPaths) {
      const st = localStat(local)
      if (!st) continue
      const remote = RemotePath.join(remoteDir, path.basename(local))
      if (st.isDirectory) await this.expandLocal(local, remote, site)
      else this.add(this.make(site.id, 'upload', local, remote, st.size))
    }
    this.resume()
  }

  private async expandLocal(local: string, remote: string, site: Site): Promise<void> {
    await this.host.browseSession(site.id)?.mkdir(remote).catch(() => undefined) // may already exist
    let names: string[]
    try {
      names = fs.readdirSync(local).sort()
    } catch {
      return
    }
    for (const name of names) {
      const l = path.join(local, name)
      const r = RemotePath.join(remote, name)
      const st = localStat(l)
      if (!st) continue
      if (st.isDirectory) await this.expandLocal(l, r, site)
      else this.add(this.make(site.id, 'upload', l, r, st.size))
    }
  }

  /** View/Edit re-upload: skips the "file exists" question. */
  enqueueEditedUpload(local: string, remote: string, site: Site): void {
    const item = this.make(site.id, 'upload', local, remote, localStat(local)?.size ?? null)
    this.forceOverwrite.add(item.id)
    this.add(item)
    this.resume()
  }

  private make(siteID: string, direction: TransferDirection, localPath: string, remotePath: string, size: number | null): TransferItem {
    return { id: newID(), siteID, direction, localPath, remotePath, size, status: 'queued', transferred: 0 }
  }

  private add(item: TransferItem): void {
    this.items.set(item.id, item)
    this.changed(item.id)
  }

  // MARK: Queue control

  resume(): void {
    if (!this.processing) return
    let free = this.host.settings().maxConcurrentTransfers - this.active
    for (const item of this.items.values()) {
      if (free <= 0) break
      if (item.status !== 'queued') continue
      free--
      this.set(item.id, { status: 'transferring' })
      void this.run(item.id)
    }
  }

  setProcessing(on: boolean): void {
    this.processing = on
    this.changed()
    if (on) this.resume()
  }

  cancel(ids: string[]): void {
    for (const id of ids) this.aborts.get(id)?.abort()
  }

  remove(ids: string[]): void {
    this.cancel(ids)
    for (const id of ids) {
      if (this.items.get(id)?.status === 'transferring') continue
      this.items.delete(id)
      this.removed.add(id)
    }
    this.changed()
  }

  retry(ids: string[]): void {
    for (const id of ids) {
      if (this.items.get(id)?.status === 'failed') {
        this.retries.delete(id)
        this.set(id, { status: 'queued', error: undefined, transferred: 0 })
      }
    }
    this.resume()
  }

  clearFinished(): void {
    this.remove([...this.items.values()].filter((i) => i.status === 'finished').map((i) => i.id))
  }

  stopAll(): void {
    this.processing = false
    this.cancel([...this.items.values()].filter((i) => i.status === 'transferring').map((i) => i.id))
    this.changed()
  }

  /** Drops pooled connections (e.g. after the site's settings changed). */
  closeIdle(): void {
    for (const pool of this.idle.values()) for (const s of pool) s.close()
    this.idle.clear()
  }

  // MARK: Worker

  private set(id: string, patch: Partial<TransferItem>, status?: TransferStatus): void {
    const item = this.items.get(id)
    if (!item) return
    Object.assign(item, patch)
    if (status) item.status = status
    if (item.status === 'finished') item.finishedAt = Date.now()
    if (item.status !== 'transferring') item.speed = undefined
    this.changed(id)
  }

  private async acquire(site: Site): Promise<RemoteSession> {
    const pool = this.idle.get(site.id) ?? []
    while (pool.length) {
      const s = pool.pop()!
      if (!s.closed) return s
    }
    return this.host.connectSession(site)
  }

  private release(session: RemoteSession, siteID: string): void {
    if (session.closed) return
    const pool = this.idle.get(siteID) ?? []
    pool.push(session)
    this.idle.set(siteID, pool)
  }

  private async run(id: string): Promise<void> {
    const item = this.items.get(id)
    if (!item) return
    const site = this.host.site(item.siteID)
    if (!site) {
      this.set(id, { error: 'Site no longer exists' }, 'failed')
      this.resume()
      return
    }
    const abort = new AbortController()
    this.aborts.set(id, abort)
    let session: RemoteSession | null = null
    try {
      session = await this.acquire(site)
      const offset = await this.resolveConflict(item, session)
      if (offset === null) {
        this.set(id, { error: 'Skipped' }, 'finished')
        this.release(session, site.id)
        return
      }
      const started = Date.now()
      const progress = (transferred: number) => {
        item.transferred = transferred
        const elapsed = (Date.now() - started) / 1000
        if (elapsed > 0.5) item.speed = (transferred - offset) / elapsed
        this.dirty.add(id)
        this.scheduleFlush()
      }
      if (item.direction === 'download') {
        fs.mkdirSync(path.dirname(item.localPath), { recursive: true })
        await session.download(item.remotePath, item.localPath, offset, abort.signal, progress)
      } else {
        await session.upload(item.localPath, item.remotePath, offset, abort.signal, progress)
      }
      if (item.size != null) item.transferred = item.size
      this.set(id, { error: undefined }, 'finished')
      this.release(session, site.id)
      this.host.transferFinished(item)
    } catch (e) {
      const message = errorMessage(e)
      if (e instanceof CancelledError || abort.signal.aborted) {
        this.set(id, { error: 'Interrupted by user' }, 'failed')
        if (session) this.release(session, site.id)
        return
      }
      // Connection-level failures: drop the session and retry a few times.
      session?.close()
      const attempts = this.retries.get(id) ?? 0
      const max = this.host.settings().retryCount
      if (attempts < max) {
        this.retries.set(id, attempts + 1)
        this.host.status(`Retrying ${path.basename(item.localPath)} (${attempts + 1}/${max}): ${message}`)
        this.set(id, {}, 'queued')
      } else {
        this.host.error(`${path.basename(item.localPath)}: ${message}`)
        this.set(id, { error: message }, 'failed')
      }
    } finally {
      this.aborts.delete(id)
      this.resume()
    }
  }

  /** Returns the resume offset (0 = from scratch) or null to skip the file. */
  private async resolveConflict(item: TransferItem, session: RemoteSession): Promise<number | null> {
    if (this.forceOverwrite.delete(item.id)) return 0
    let source: { size: number | null; modified: number | null }
    let target: { size: number | null; modified: number | null }
    if (item.direction === 'download') {
      const local = localStat(item.localPath)
      if (!local) return 0
      const remote = await session.stat(item.remotePath)
      source = { size: remote?.size ?? item.size, modified: remote?.modified ?? null }
      target = local
    } else {
      const remote = await session.stat(item.remotePath)
      if (!remote) return 0
      const local = localStat(item.localPath)
      source = { size: local?.size ?? item.size, modified: local?.modified ?? null }
      target = remote
    }

    const settings = this.host.settings()
    let action: OverwriteAction = item.direction === 'download' ? settings.defaultOverwriteDownload : settings.defaultOverwriteUpload
    if (action === 'ask') action = this.overwriteForAll.get(item.direction) ?? 'ask'
    let newName: string | undefined
    if (action === 'ask') {
      const answer = await ask(this.host.prompter, {
        kind: 'overwrite',
        direction: item.direction,
        source: item.direction === 'download' ? item.remotePath : item.localPath,
        target: item.direction === 'download' ? item.localPath : item.remotePath,
        sourceSize: source.size,
        targetSize: target.size,
        sourceModified: source.modified,
        targetModified: target.modified,
      })
      if (!answer) return null
      action = answer.action
      newName = answer.newName
      if (answer.applyToAll) this.overwriteForAll.set(item.direction, answer.action)
    }

    switch (action) {
      case 'overwrite':
        return 0
      case 'skip':
        return null
      case 'overwriteIfDifferentSize':
        return source.size === target.size ? null : 0
      case 'overwriteIfNewer':
        return source.modified != null && target.modified != null && source.modified <= target.modified ? null : 0
      case 'resume': {
        // Resume only when the target is a shorter prefix; equal size = already complete.
        if (target.size == null || source.size == null) return 0
        if (target.size === source.size) return null
        return target.size < source.size ? target.size : 0
      }
      case 'rename':
        if (item.direction === 'download') {
          item.localPath = newName ? path.join(path.dirname(item.localPath), newName) : uniqueLocalName(item.localPath)
        } else {
          const name =
            newName ??
            (await ask(this.host.prompter, {
              kind: 'text',
              title: 'Rename file',
              message: 'Enter a new name for the remote file:',
              initial: RemotePath.lastComponent(item.remotePath),
            }))
          if (!name) return null
          item.remotePath = RemotePath.join(RemotePath.parent(item.remotePath), name)
        }
        this.changed(item.id)
        return 0
    }
  }

  // MARK: Publishing

  private changed(id?: string): void {
    if (id) this.dirty.add(id)
    this.scheduleFlush()
    if (!this.saveTimer) {
      this.saveTimer = setTimeout(() => {
        this.saveTimer = null
        this.store.save(this.all())
      }, 500)
    }
  }

  private scheduleFlush(): void {
    if (this.flushTimer) return
    this.flushTimer = setTimeout(() => this.flush(), 100)
  }

  private flush(): void {
    this.flushTimer = null
    const upserts = [...this.dirty].map((id) => this.items.get(id)).filter((i): i is TransferItem => !!i)
    this.host.publish({ upserts: upserts.map((i) => ({ ...i })), removed: [...this.removed], processing: this.processing })
    this.dirty.clear()
    this.removed.clear()
  }

  /** Writes the queue immediately (on quit). */
  persist(): void {
    if (this.saveTimer) clearTimeout(this.saveTimer)
    this.saveTimer = null
    this.store.save(this.all())
  }
}

export function uniqueLocalName(file: string): string {
  const dir = path.dirname(file)
  const ext = path.extname(file)
  const base = path.basename(file, ext)
  for (let n = 1; ; n++) {
    const candidate = path.join(dir, `${base} (${n})${ext}`)
    if (!fs.existsSync(candidate)) return candidate
  }
}

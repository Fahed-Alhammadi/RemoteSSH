import fs from 'node:fs'
import path from 'node:path'
import { newID } from '../shared/site'
import type { AppSettings, FileEntry, OverwriteAction, Site, TransferDirection, TransferItem, TransferStatus } from '../shared/types'
import { errorMessage, RemotePath } from '../shared/util'
import { localChild, localStat } from './engine/localFS'
import { ask, CancelledError, isPermanentError, type Prompter, type RemoteSession } from './engine/session'
import type { QueueStore } from './store/settingsStore'

interface TransferHost {
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
  /** Ids of queued items in queue order, and the number transferring: kept in step by `track`, so
   *  starting the next item never scans the whole (maybe huge) queue. */
  private queued = new Set<string>()
  private active = 0
  private aborts = new Map<string, AbortController>()
  private idle = new Map<string, RemoteSession[]>()
  private idleTimer: NodeJS.Timeout | null = null
  private retries = new Map<string, number>()
  /** Items waiting out a retry delay: id → time they may start again. */
  private retryAt = new Map<string, number>()
  private retryTimer: NodeJS.Timeout | null = null
  /** Items that already got their free retry after failing on a reused pooled connection. */
  private freshRetry = new Set<string>()
  /** Items that have written (part of) their target: a retry resumes it instead of asking about "its" file. */
  private wroteTarget = new Set<string>()
  private overwriteForAll = new Map<TransferDirection, Exclude<OverwriteAction, 'ask'>>()
  /** Overwrite questions are asked one at a time, so "apply to all" also covers questions already waiting. */
  private promptTurn: Promise<unknown> = Promise.resolve()
  private forceOverwrite = new Set<string>()
  /** Running items the user removed: dropped once their worker has stopped. */
  private removeWhenStopped = new Set<string>()
  private dirty = new Set<string>()
  private removed = new Set<string>()
  private flushTimer: NodeJS.Timeout | null = null
  private saveTimer: NodeJS.Timeout | null = null

  constructor(private readonly host: TransferHost, private readonly store: QueueStore) {
    for (const item of store.load()) {
      // Unfinished items come back as failed, ready to retry: starting them on their own (with password
      // questions for other sites, or a quickconnect site that is gone) would surprise.
      if (item.status === 'queued') Object.assign(item, { status: 'failed', error: 'Interrupted when RemoteSSH quit' })
      this.items.set(item.id, item)
      this.track(item, undefined)
    }
  }

  all(): TransferItem[] {
    return [...this.items.values()]
  }

  /** Keeps `queued` and `active` in step with an item's status change. */
  private track(item: TransferItem, before: TransferStatus | undefined): void {
    if (before === item.status) return
    if (before === 'queued') this.queued.delete(item.id)
    if (before === 'transferring') this.active--
    if (item.status === 'queued') this.queued.add(item.id)
    if (item.status === 'transferring') this.active++
  }

  private forget(id: string): void {
    const item = this.items.get(id)
    if (!item) return
    this.items.delete(id)
    this.queued.delete(id)
    if (item.status === 'transferring') this.active--
    for (const m of [this.retries, this.retryAt]) m.delete(id)
    for (const set of [this.freshRetry, this.wroteTarget, this.forceOverwrite]) set.delete(id)
    this.removed.add(id)
  }

  // MARK: Enqueue

  async enqueueDownload(entries: FileEntry[], remoteDir: string, localDir: string, site: Site): Promise<void> {
    // The folders are listed on the connection that was current when the download started, so a connect
    // to another server meanwhile can't mix in that server's files.
    const session = this.host.browseSession(site.id)
    for (const entry of entries) {
      const remote = RemotePath.join(remoteDir, entry.name)
      const local = this.localTarget(localDir, entry.name)
      if (local == null) continue
      if (entry.isDirectory) {
        if (session) await this.expandRemote(session, remote, local, site, 0)
      } else this.add(this.make(site.id, 'download', local, remote, entry.size))
    }
    this.resume()
  }

  /**
   * Links to folders are not followed (as on the Mac): a link back to a parent folder would otherwise
   * recurse until the path is too long, queueing every file once per level.
   */
  private async expandRemote(session: RemoteSession, remote: string, local: string, site: Site, depth: number): Promise<void> {
    if (session.closed) return
    if (depth >= MAX_DEPTH) return this.host.error(`Skipped ${remote}: folders nested more than ${MAX_DEPTH} levels deep.`)
    try {
      fs.mkdirSync(local, { recursive: true })
      for (const child of await session.list(remote)) {
        const r = RemotePath.join(remote, child.name)
        const l = this.localTarget(local, child.name)
        if (l == null) continue
        if (child.isDirectory && child.isLink) this.host.status(`Skipped ${r}: links to folders are not followed.`)
        else if (child.isDirectory) await this.expandRemote(session, r, l, site, depth + 1)
        else this.add(this.make(site.id, 'download', l, r, child.size))
      }
    } catch (e) {
      this.host.error(`Could not list ${remote}: ${errorMessage(e)}`)
    }
  }

  /** Local path for a name from a server listing; names that would escape the folder are skipped. */
  private localTarget(dir: string, name: string): string | null {
    const local = localChild(dir, name)
    if (local == null) this.host.error(`Skipped "${name}": not a valid local file name.`)
    return local
  }

  async enqueueUpload(localPaths: string[], remoteDir: string, site: Site): Promise<void> {
    const session = this.host.browseSession(site.id)
    for (const local of localPaths) {
      const st = localStat(local)
      if (!st) continue
      const remote = RemotePath.join(remoteDir, path.basename(local))
      if (st.isDirectory) await this.expandLocal(session, local, remote, site, new Set())
      else this.add(this.make(site.id, 'upload', local, remote, st.size))
    }
    this.resume()
  }

  /** `seen` holds the real paths of the folders being expanded, so a symlink loop is not followed forever. */
  private async expandLocal(session: RemoteSession | null, local: string, remote: string, site: Site, seen: Set<string>): Promise<void> {
    if (session?.closed) return
    let real: string
    try {
      real = fs.realpathSync(local)
    } catch {
      return
    }
    if (seen.has(real)) return this.host.error(`Skipped ${local}: it links back to a folder that is already being uploaded.`)
    seen.add(real)
    await session?.mkdir(remote).catch(() => undefined) // may already exist
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
      if (st.isDirectory) await this.expandLocal(session, l, r, site, seen)
      else this.add(this.make(site.id, 'upload', l, r, st.size))
    }
    seen.delete(real)
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
    this.track(item, undefined)
    this.changed(item.id)
  }

  // MARK: Queue control

  resume(): void {
    if (!this.queued.size && !this.active) {
      // "Apply to all" answers belong to the batch that is running; a later batch is asked again.
      this.overwriteForAll.clear()
      this.scheduleIdleClose()
    }
    if (!this.processing) return
    let free = this.host.settings().maxConcurrentTransfers - this.active
    if (free <= 0) return
    const now = Date.now()
    const start: string[] = []
    for (const id of this.queued) {
      if (start.length >= free) break
      const due = this.retryAt.get(id)
      if (due != null && due > now) continue
      start.push(id)
    }
    for (const id of start) {
      this.retryAt.delete(id)
      this.set(id, {}, 'transferring')
      void this.run(id)
    }
    this.scheduleRetryWake()
  }

  /** Wakes the queue when the earliest retry delay has passed. */
  private scheduleRetryWake(): void {
    if (this.retryTimer) clearTimeout(this.retryTimer)
    this.retryTimer = null
    if (!this.retryAt.size || !this.processing) return
    const next = Math.min(...this.retryAt.values())
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null
      this.resume()
    }, Math.max(0, next - Date.now()) + 10)
  }

  /** Pooled connections are closed a minute after the queue ran empty. */
  private scheduleIdleClose(): void {
    if (this.idleTimer || !this.idle.size) return
    this.idleTimer = setTimeout(() => {
      this.idleTimer = null
      if (!this.queued.size && !this.active) this.closeIdle()
    }, IDLE_CLOSE_MS)
    this.idleTimer.unref?.()
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
      if (this.items.get(id)?.status === 'transferring') {
        this.removeWhenStopped.add(id)
        continue
      }
      this.forget(id)
    }
    this.changed()
  }

  retry(ids: string[]): void {
    for (const id of ids) {
      if (this.items.get(id)?.status === 'failed') {
        this.retries.delete(id)
        this.freshRetry.delete(id)
        this.set(id, { error: undefined, transferred: 0 }, 'queued')
      }
    }
    this.resume()
  }

  clearFinished(): void {
    this.remove([...this.items.values()].filter((i) => i.status === 'finished').map((i) => i.id))
  }

  /** Stops running transfers and marks waiting ones interrupted too, so "stop all" leaves nothing pending. */
  stopAll(): void {
    this.processing = false
    for (const id of [...this.queued]) this.set(id, { error: 'Interrupted by user' }, 'failed')
    this.retryAt.clear()
    this.cancel([...this.aborts.keys()])
    this.changed()
  }

  /** Drops pooled connections (after a disconnect, or when the site or the settings changed). */
  closeIdle(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer)
    this.idleTimer = null
    for (const pool of this.idle.values()) for (const s of pool) s.close()
    this.idle.clear()
  }

  // MARK: Worker

  private set(id: string, patch: Partial<TransferItem>, status?: TransferStatus): void {
    const item = this.items.get(id)
    if (!item) return
    const before = item.status
    Object.assign(item, patch)
    if (status) item.status = status
    this.track(item, before)
    if (item.status === 'finished' || item.status === 'failed') {
      this.forceOverwrite.delete(id)
      this.wroteTarget.delete(id)
      this.freshRetry.delete(id)
    }
    if (item.status === 'finished') item.finishedAt = Date.now()
    if (item.status !== 'transferring') item.speed = undefined
    this.changed(id)
  }

  /** A pooled connection (`reused`) or a new one. */
  private async acquire(site: Site): Promise<{ session: RemoteSession; reused: boolean }> {
    if (this.idleTimer) clearTimeout(this.idleTimer)
    this.idleTimer = null
    const pool = this.idle.get(site.id) ?? []
    while (pool.length) {
      const s = pool.pop()!
      if (!s.closed) return { session: s, reused: true }
    }
    return { session: await this.host.connectSession(site), reused: false }
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
      this.set(id, { error: 'Site no longer exists (quickconnect sites are not kept after a restart)' }, 'failed')
      // Not synchronously: this runs inside resume()'s loop, which would start more workers than allowed.
      queueMicrotask(() => this.resume())
      return
    }
    const abort = new AbortController()
    this.aborts.set(id, abort)
    let session: RemoteSession | null = null
    let reused = false
    try {
      ;({ session, reused } = await this.acquire(site))
      if (abort.signal.aborted) throw new CancelledError()
      const offset = await this.resolveConflict(item, session, abort.signal)
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
      this.wroteTarget.add(id)
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
        // e.g. "Interrupted by user", or a password prompt / host key the user declined (not retried).
        this.set(id, { error: e instanceof CancelledError ? message : 'Interrupted by user' }, 'failed')
        if (session && !session.closed) this.release(session, site.id)
        return
      }
      if (isPermanentError(e)) {
        // Permission denied, no such file, disk full, login rejected: trying again can't help.
        if (session && !session.closed) this.release(session, site.id)
        this.host.error(`${path.basename(item.localPath)}: ${message}`)
        this.set(id, { error: message }, 'failed')
        return
      }
      // Connection-level failures: drop the session and retry.
      session?.close()
      if (reused && !this.freshRetry.has(id)) {
        // The server may have closed an idle pooled connection: one free try on a new connection.
        this.freshRetry.add(id)
        this.set(id, {}, 'queued')
        return
      }
      const attempts = this.retries.get(id) ?? 0
      const max = this.host.settings().retryCount
      if (attempts < max) {
        this.retries.set(id, attempts + 1)
        const delay = Math.min(1000 * 2 ** attempts, 30_000)
        this.host.status(`Retrying ${path.basename(item.localPath)} in ${delay / 1000} s (${attempts + 1}/${max}): ${message}`)
        this.retryAt.set(id, Date.now() + delay)
        this.set(id, {}, 'queued')
      } else {
        this.host.error(`${path.basename(item.localPath)}: ${message}`)
        this.set(id, { error: message }, 'failed')
      }
    } finally {
      this.aborts.delete(id)
      if (this.removeWhenStopped.delete(id)) this.remove([id])
      this.resume()
    }
  }

  /** Runs overwrite questions one after another (several workers may hit existing files at once). */
  private inTurn<T>(task: () => Promise<T>): Promise<T> {
    const result = this.promptTurn.then(task, task)
    this.promptTurn = result.catch(() => undefined)
    return result
  }

  /** Returns the resume offset (0 = from scratch) or null to skip the file. */
  private async resolveConflict(item: TransferItem, session: RemoteSession, signal: AbortSignal): Promise<number | null> {
    const ownPartial = this.wroteTarget.has(item.id)
    if (this.forceOverwrite.has(item.id) && !ownPartial) return 0
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
    // A retry continues the file this item already started instead of asking about it.
    if (ownPartial) action = 'resume'
    let newName: string | undefined
    if (action === 'ask') {
      const answer = await this.inTurn(async () => {
        if (signal.aborted) throw new CancelledError()
        // Re-read: an earlier question may have been answered with "apply to all" while this one waited.
        const all = this.overwriteForAll.get(item.direction)
        if (all) return { action: all, applyToAll: false, newName: undefined }
        return ask(this.host.prompter, {
          kind: 'overwrite',
          direction: item.direction,
          source: item.direction === 'download' ? item.remotePath : item.localPath,
          target: item.direction === 'download' ? item.localPath : item.remotePath,
          sourceSize: source.size,
          targetSize: target.size,
          sourceModified: source.modified,
          targetModified: target.modified,
        })
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
          // The dialog suggests the existing name; keeping it (or naming another existing file) must not overwrite.
          const target = (newName && localChild(path.dirname(item.localPath), newName)) || item.localPath
          item.localPath = localStat(target) ? uniqueLocalName(target) : target
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
          if (!isPlainName(name)) throw new CancelledError(`"${name}" is not a valid file name.`)
          const target = RemotePath.join(RemotePath.parent(item.remotePath), name)
          if (await session.stat(target)) throw new CancelledError(`${target} already exists; choose another name.`)
          item.remotePath = target
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
        void this.store.saveAsync(this.all())
      }, SAVE_DELAY_MS)
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

const MAX_DEPTH = 64
const IDLE_CLOSE_MS = 60_000
const SAVE_DELAY_MS = 2000

/** A single file name: no path separators, not "." or "..", no control characters. */
export function isPlainName(name: string): boolean {
  // eslint-disable-next-line no-control-regex
  return !!name && name !== '.' && name !== '..' && !/[/\\\u0000-\u001f\u007f]/.test(name)
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

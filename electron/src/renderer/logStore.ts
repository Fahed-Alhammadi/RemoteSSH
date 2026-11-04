import { useSyncExternalStore } from 'react'
import type { LogLine } from '../shared/types'

const MAX_LOG = 5000
let lines: LogLine[] = []
const listeners = new Set<() => void>()

/**
 * The message log lives outside React state so that a log batch (every 50 ms while busy)
 * re-renders only the components that show it, not the whole window.
 */
export const logStore = {
  append(more: LogLine[]) {
    if (!more.length) return
    const next = lines.concat(more)
    lines = next.length > MAX_LOG ? next.slice(-MAX_LOG) : next
    for (const l of listeners) l()
  },
  subscribe(listener: () => void) {
    listeners.add(listener)
    return () => void listeners.delete(listener)
  },
  get: () => lines,
}

export const useLog = () => useSyncExternalStore(logStore.subscribe, logStore.get)

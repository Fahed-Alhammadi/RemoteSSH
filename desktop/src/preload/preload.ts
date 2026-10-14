import { contextBridge, ipcRenderer, webUtils } from 'electron'
import { Events, invokeMethods, type RemoteSSHApi } from '../shared/api'

const invoke = Object.fromEntries(
  invokeMethods.map((method) => [method, (...args: unknown[]) => ipcRenderer.invoke(method, ...args)]),
)

function on<T extends unknown[]>(channel: string, spread = false) {
  return (cb: (...args: T) => void) => {
    const listener = (_e: unknown, payload: unknown) => (spread ? cb(...(payload as T)) : cb(...([payload] as T)))
    ipcRenderer.on(channel, listener)
    return () => void ipcRenderer.removeListener(channel, listener)
  }
}

const api: RemoteSSHApi = {
  ...(invoke as unknown as Omit<RemoteSSHApi, 'platform' | 'pathForFile' | `on${string}`>),
  platform: process.platform,
  pathForFile: (file) => webUtils.getPathForFile(file),
  onLog: on(Events.log),
  onQueue: on(Events.queue),
  onPrompt: on(Events.prompt),
  onConnection: on(Events.connection),
  onMenu: on(Events.menu),
  onSitesChanged: on(Events.sites),
  onRefresh: on(Events.refresh, true),
}

contextBridge.exposeInMainWorld('remotessh', api)

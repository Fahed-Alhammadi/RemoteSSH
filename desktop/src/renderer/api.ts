import type { RemoteSSHApi } from '../shared/api'

declare global {
  interface Window {
    remotessh: RemoteSSHApi
  }
}

export const api = window.remotessh

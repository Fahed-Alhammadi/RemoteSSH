import path from 'node:path'
import { readJSON, writeJSON } from './jsonFile'

/**
 * FTP servers (`[host]:port`) where "explicit TLS if available" worked once. Saved across restarts, so a
 * later connection that is downgraded to plain FTP (e.g. by someone stripping AUTH TLS) is refused.
 */
export class TLSHostsStore {
  private readonly file: string
  private hosts: Set<string>

  constructor(dir: string) {
    this.file = path.join(dir, 'tls-hosts.json')
    const list = readJSON<unknown>(this.file, [])
    this.hosts = new Set(Array.isArray(list) ? list.filter((h): h is string => typeof h === 'string') : [])
  }

  private static id(host: string, port: number): string {
    return `[${host.toLowerCase()}]:${port}`
  }

  has(host: string, port: number): boolean {
    return this.hosts.has(TLSHostsStore.id(host, port))
  }

  add(host: string, port: number): void {
    const id = TLSHostsStore.id(host, port)
    if (this.hosts.has(id)) return
    this.hosts.add(id)
    writeJSON(this.file, [...this.hosts].sort())
  }
}

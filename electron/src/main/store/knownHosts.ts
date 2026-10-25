import crypto from 'node:crypto'
import path from 'node:path'
import { readJSON, writeJSON } from './jsonFile'

type HostKeyStatus = 'trusted' | 'unknown' | 'changed'

/** Trusted SSH host keys: `[host]:port` → OpenSSH public key line ("type base64"). */
export class KnownHostsStore {
  private readonly file: string
  private keys: Record<string, string>

  constructor(dir: string) {
    this.file = path.join(dir, 'known_hosts.json')
    this.keys = readJSON<Record<string, string>>(this.file, {})
  }

  private static id(host: string, port: number): string {
    return `[${host.toLowerCase()}]:${port}`
  }

  check(host: string, port: number, key: string): HostKeyStatus {
    const known = this.keys[KnownHostsStore.id(host, port)]
    if (!known) return 'unknown'
    return known === key ? 'trusted' : 'changed'
  }

  trust(host: string, port: number, key: string): void {
    this.keys[KnownHostsStore.id(host, port)] = key
    writeJSON(this.file, this.keys)
  }
}

/** Raw SSH public key blob → `{ type, line }` where line is "type base64". */
export function describeHostKey(blob: Buffer): { type: string; line: string; fingerprint: string } {
  const len = blob.length >= 4 ? blob.readUInt32BE(0) : 0
  const type = len > 0 && len < 64 ? blob.subarray(4, 4 + len).toString('ascii') : 'unknown'
  return { type, line: `${type} ${blob.toString('base64')}`, fingerprint: fingerprint(blob) }
}

/** "SHA256:base64" fingerprint, the same format as `ssh-keygen -lf`. */
export function fingerprint(blob: Buffer): string {
  return `SHA256:${crypto.createHash('sha256').update(blob).digest('base64').replace(/=+$/, '')}`
}

import path from 'node:path'
import { readJSON, writeJSON } from './jsonFile'

export type CertificateStatus = 'trusted' | 'unknown' | 'changed'

/**
 * FTPS certificates the user accepted although they could not be verified: `[host]:port` → SHA-256
 * fingerprint. "Always trust" pins the exact certificate the user saw (saved here, used only while the
 * site's "trust" checkbox is on); "accept once" lasts for this run. Another certificate is asked about again.
 */
export class CertificateStore {
  private readonly file: string
  private pins: Record<string, string>
  private accepted = new Map<string, string>()

  constructor(dir: string) {
    this.file = path.join(dir, 'certificates.json')
    const pins = readJSON<Record<string, string>>(this.file, {})
    this.pins = pins && typeof pins === 'object' ? pins : {}
  }

  private static id(host: string, port: number): string {
    return `[${host.toLowerCase()}]:${port}`
  }

  hasPin(host: string, port: number): boolean {
    return typeof this.pins[CertificateStore.id(host, port)] === 'string'
  }

  /** `usePin`: the site's "trust this certificate" setting is on. */
  check(host: string, port: number, fingerprint: string, usePin: boolean): CertificateStatus {
    const id = CertificateStore.id(host, port)
    if (!fingerprint) return 'unknown'
    const pin = usePin ? this.pins[id] : undefined
    const once = this.accepted.get(id)
    if (pin === fingerprint || once === fingerprint) return 'trusted'
    return pin || once ? 'changed' : 'unknown'
  }

  trust(host: string, port: number, fingerprint: string, persist: boolean): void {
    const id = CertificateStore.id(host, port)
    this.accepted.set(id, fingerprint)
    if (!persist) return
    this.pins[id] = fingerprint
    writeJSON(this.file, this.pins)
  }
}

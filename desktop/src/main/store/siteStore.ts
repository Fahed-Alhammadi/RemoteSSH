import path from 'node:path'
import { normalizeSite } from '../../shared/site'
import type { Site, SitesState, SitesUpdate } from '../../shared/types'
import { readJSON, writeJSON } from './jsonFile'

/** OS-backed encryption (Electron `safeStorage`: DPAPI on Windows, Secret Service/KWallet on Linux). */
export interface SecretCipher {
  available(): boolean
  encrypt(plain: string): string
  decrypt(encoded: string): string
}

/**
 * Site Manager persistence. Site metadata is `sites.json`; passwords are encrypted with the OS
 * keyring into `secrets.json`. Without a keyring, passwords are never written to disk.
 */
export class SiteStore {
  private readonly sitesFile: string
  private readonly secretsFile: string
  private secrets: Record<string, string>

  constructor(dir: string, private readonly cipher: SecretCipher) {
    this.sitesFile = path.join(dir, 'sites.json')
    this.secretsFile = path.join(dir, 'secrets.json')
    this.secrets = readJSON<Record<string, string>>(this.secretsFile, {})
  }

  load(): Site[] {
    const raw = readJSON<Partial<Site>[]>(this.sitesFile, [])
    return Array.isArray(raw) ? raw.map(normalizeSite) : []
  }

  state(): SitesState {
    const sites = this.load()
    return {
      sites,
      withPassword: sites.filter((s) => this.secrets[s.id]).map((s) => s.id),
      canStorePasswords: this.cipher.available(),
    }
  }

  password(id: string): string | null {
    const encoded = this.secrets[id]
    if (!encoded || !this.cipher.available()) return null
    try {
      return this.cipher.decrypt(encoded)
    } catch {
      return null
    }
  }

  save(update: SitesUpdate): void {
    const sites = update.sites.map(normalizeSite)
    writeJSON(this.sitesFile, sites)
    const ids = new Set(sites.map((s) => s.id))
    let changed = false
    for (const id of Object.keys(this.secrets)) {
      if (!ids.has(id)) {
        delete this.secrets[id]
        changed = true
      }
    }
    for (const [id, pw] of Object.entries(update.passwords)) {
      const key = id.toUpperCase()
      if (pw === null || pw === '') {
        if (key in this.secrets) {
          delete this.secrets[key]
          changed = true
        }
      } else if (this.cipher.available()) {
        this.secrets[key] = this.cipher.encrypt(pw)
        changed = true
      }
    }
    if (changed) writeJSON(this.secretsFile, this.secrets)
  }

  update(site: Site): void {
    const sites = this.load()
    const idx = sites.findIndex((s) => s.id === site.id)
    if (idx < 0) return
    sites[idx] = site
    writeJSON(this.sitesFile, sites)
  }
}

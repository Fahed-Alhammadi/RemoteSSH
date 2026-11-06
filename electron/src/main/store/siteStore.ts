import path from 'node:path'
import { normalizeSite } from '../../shared/site'
import type { Site, SitesState, SitesUpdate } from '../../shared/types'
import { readJSON, writeJSON } from './jsonFile'

/** OS-backed encryption (Electron `safeStorage`: DPAPI on Windows, Secret Service/KWallet on Linux). */
export interface SecretCipher {
  available(): boolean
  encrypt(plain: string): Promise<string>
  decrypt(encoded: string): Promise<string>
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

  async password(id: string): Promise<string | null> {
    const encoded = this.secrets[id]
    if (!encoded || !this.cipher.available()) return null
    try {
      return await this.cipher.decrypt(encoded)
    } catch {
      return null
    }
  }

  async save(update: SitesUpdate): Promise<void> {
    // Encrypt first, so the files and `secrets` are then updated in one synchronous step.
    const encrypted: Record<string, string> = {}
    if (this.cipher.available()) {
      for (const [id, pw] of Object.entries(update.passwords)) {
        if (pw) encrypted[id.toUpperCase()] = await this.cipher.encrypt(pw)
      }
    }
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
      } else if (key in encrypted) {
        this.secrets[key] = encrypted[key]
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

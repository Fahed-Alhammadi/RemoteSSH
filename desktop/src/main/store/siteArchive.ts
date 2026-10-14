import { newID, normalizeSite } from '../../shared/site'
import type { Site } from '../../shared/types'

/**
 * Portable site list (`.remotessh` JSON), identical to the macOS app's `SiteArchive`:
 * `{ format, version, exportedAt, sites, passwords? }` with passwords keyed by site id.
 */
export const ARCHIVE_EXTENSION = 'remotessh'
const FORMAT = 'remotessh.sites'
const VERSION = 1

export class ArchiveError extends Error {}

export function encodeArchive(sites: Site[], passwords?: Record<string, string>): string {
  const archive: Record<string, unknown> = {
    exportedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'), // Swift's .iso8601 rejects fractions
    format: FORMAT,
    sites,
    version: VERSION,
  }
  if (passwords) archive.passwords = passwords
  return JSON.stringify(archive, null, 2)
}

/** Sites ready to merge into an existing list: fresh ids, so importing twice never collides. */
export function decodeArchive(text: string): { sites: Site[]; passwords: Record<string, string> } {
  let parsed: { format?: unknown; version?: unknown; sites?: unknown; passwords?: unknown }
  try {
    parsed = JSON.parse(text)
  } catch {
    throw new ArchiveError('This file is not a RemoteSSH site export.')
  }
  if (!parsed || parsed.format !== FORMAT || !Array.isArray(parsed.sites)) {
    throw new ArchiveError('This file is not a RemoteSSH site export.')
  }
  if (typeof parsed.version !== 'number' || parsed.version > VERSION) {
    throw new ArchiveError('This file was exported by a newer version of RemoteSSH.')
  }
  const oldPasswords: Record<string, string> = {}
  if (parsed.passwords && typeof parsed.passwords === 'object') {
    for (const [k, v] of Object.entries(parsed.passwords as Record<string, unknown>)) {
      if (typeof v === 'string') oldPasswords[k.toUpperCase()] = v
    }
  }
  const sites: Site[] = []
  const passwords: Record<string, string> = {}
  for (const raw of parsed.sites as Partial<Site>[]) {
    const site = normalizeSite(raw)
    const pw = oldPasswords[site.id]
    site.id = newID()
    if (pw) passwords[site.id] = pw
    sites.push(site)
  }
  return { sites, passwords }
}

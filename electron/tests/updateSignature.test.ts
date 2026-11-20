// Signed updates: scripts/sign-update.mjs (release workflow) against src/main/updateSignature.ts (the app).
import { execFileSync } from 'node:child_process'
import { generateKeyPairSync } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { APP_ID, MANIFEST, UPDATE_PUBLIC_KEY, checkFiles, checkManifest, verifyUpdate } from '../src/main/updateSignature'

const SCRIPT = path.resolve(__dirname, '../../scripts/sign-update.mjs')
const SOURCE = path.resolve(__dirname, '../src/main/updateSignature.ts')
const LOCAL_KEY = path.resolve(__dirname, '../../keys/UPDATE_SIGNING_KEY.pem')

function keyPair() {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519')
  return {
    priv: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
    pub: publicKey.export({ type: 'spki', format: 'pem' }).toString(),
  }
}

function signDir(dir: string, key: string, version: string, source: string) {
  execFileSync(process.execPath, [SCRIPT, dir, APP_ID, version, source], {
    env: { ...process.env, UPDATE_SIGNING_KEY: key },
    stdio: 'pipe',
  })
}

/** A release folder with two packages, signed with a fresh key. */
function release() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rssh-sign-'))
  fs.writeFileSync(path.join(dir, 'RemoteSSH-9.8.7-win-x64.exe'), 'installer')
  fs.writeFileSync(path.join(dir, 'RemoteSSH-9.8.7-linux-x86_64.AppImage'), 'appimage')
  fs.writeFileSync(path.join(dir, 'latest.yml'), 'not a package')
  const k = keyPair()
  fs.writeFileSync(path.join(dir, 'key.ts'), `export const K = \`${k.pub}\``)
  signDir(dir, k.priv, '9.8.7', path.join(dir, 'key.ts'))
  return {
    dir,
    k,
    body: fs.readFileSync(path.join(dir, MANIFEST)),
    sig: fs.readFileSync(path.join(dir, `${MANIFEST}.sig`), 'utf8'),
    done: () => fs.rmSync(dir, { recursive: true, force: true }),
  }
}

describe('signed updates', () => {
  it('accepts a signed release; only packages are listed', async () => {
    const r = release()
    try {
      const m = checkManifest(r.body, r.sig, '9.8.7', r.k.pub)
      expect(Object.keys(m.files).sort()).toEqual(['RemoteSSH-9.8.7-linux-x86_64.AppImage', 'RemoteSSH-9.8.7-win-x64.exe'])
      await checkFiles([path.join(r.dir, 'RemoteSSH-9.8.7-win-x64.exe')], m)
    } finally {
      r.done()
    }
  })

  it('refuses a changed package, manifest, version or key', async () => {
    const r = release()
    try {
      const m = checkManifest(r.body, r.sig, '9.8.7', r.k.pub)
      fs.writeFileSync(path.join(r.dir, 'evil.exe'), 'installer!')
      await expect(checkFiles([path.join(r.dir, 'evil.exe')], m)).rejects.toThrow(/not signed/)
      await expect(checkFiles([], m)).rejects.toThrow(/empty/)
      const tampered = Buffer.from(r.body.toString().replace('9.8.7', '9.8.8'))
      expect(() => checkManifest(tampered, r.sig, '9.8.8', r.k.pub)).toThrow(/not signed/)
      expect(() => checkManifest(r.body, r.sig, '9.8.8', r.k.pub)).toThrow(/not for RemoteSSH 9.8.8/)
      expect(() => checkManifest(r.body, r.sig, '9.8.7', keyPair().pub)).toThrow(/not signed/)
      expect(() => checkManifest(r.body, r.sig, '9.8.7')).toThrow(/not signed/) // the real key didn't sign it
      expect(() => checkManifest(r.body, 'AAAA', '9.8.7', r.k.pub)).toThrow(/not signed/)
    } finally {
      r.done()
    }
  })

  it('verifyUpdate fetches the manifest next to the packages and fails closed', async () => {
    const r = release()
    const served = new Map([
      [`https://x/${MANIFEST}`, r.body],
      [`https://x/${MANIFEST}.sig`, Buffer.from(r.sig)],
    ])
    const fetch = async (url: string) => {
      const b = served.get(url)
      return b ? new Response(new Uint8Array(b)) : new Response('missing', { status: 404 })
    }
    try {
      const exe = path.join(r.dir, 'RemoteSSH-9.8.7-win-x64.exe')
      await expect(verifyUpdate('https://x', '9.8.7', [exe], fetch)).rejects.toThrow(/not signed/)
      await expect(verifyUpdate('https://y', '9.8.7', [exe], fetch)).rejects.toThrow(/no signature/)
    } finally {
      r.done()
    }
  })

  it('the script refuses a key that is not the app key', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rssh-sign-'))
    fs.writeFileSync(path.join(dir, 'a.exe'), 'x')
    try {
      expect(() => signDir(dir, keyPair().priv, '1.0.0', SOURCE)).toThrow()
      expect(fs.existsSync(path.join(dir, MANIFEST))).toBe(false)
    } finally {
      fs.rmSync(dir, { recursive: true, force: true })
    }
  })

  // Local only: keys/ (git-ignored) holds the private key the release workflow uses.
  it.skipIf(!fs.existsSync(LOCAL_KEY))('keys/UPDATE_SIGNING_KEY.pem belongs to UPDATE_PUBLIC_KEY', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rssh-sign-'))
    fs.writeFileSync(path.join(dir, 'a.exe'), 'x')
    try {
      signDir(dir, fs.readFileSync(LOCAL_KEY, 'utf8'), '1.0.0', SOURCE)
      checkManifest(fs.readFileSync(path.join(dir, MANIFEST)), fs.readFileSync(path.join(dir, `${MANIFEST}.sig`), 'utf8'), '1.0.0', UPDATE_PUBLIC_KEY)
    } finally {
      fs.rmSync(dir, { recursive: true, force: true })
    }
  })
})

// Signed updates. Every release carries update-signatures.json (app, version and the SHA-512 of every package) and
// update-signatures.json.sig (its Ed25519 signature, base64). The release workflow makes them with
// scripts/sign-update.mjs and the private key UPDATE_SIGNING_KEY, a secret of the `desktop-release` environment (release
// tags only). A downloaded update is installed only when the signature matches UPDATE_PUBLIC_KEY,
// the manifest is for the expected version, and every downloaded file's SHA-512 is listed in it.
// No Electron imports: tested in tests/updateSignature.test.ts.
import { createHash, createPublicKey, verify } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { basename } from 'node:path'

/** Public half of the update key (private half: keys/UPDATE_SIGNING_KEY.pem). scripts/sign-update.mjs reads it from here. */
export const UPDATE_PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAg17hZdrkZ1h5z2SalL38Cn4Vb1afmsUtHOVpMAR5884=
-----END PUBLIC KEY-----`

export const MANIFEST = 'update-signatures.json'
export const APP_ID = 'app.remotessh.RemoteSSH'

export type UpdateManifest = { app: string; version: string; files: Record<string, string> }

/** Checks the manifest's signature and that it is this app's manifest for `version`; throws otherwise. */
export function checkManifest(body: Buffer, signature: string, version: string, publicKey = UPDATE_PUBLIC_KEY): UpdateManifest {
  const sig = Buffer.from(signature.trim(), 'base64')
  if (sig.length !== 64 || !verify(null, body, createPublicKey(publicKey), sig)) {
    throw new Error('The update is not signed by RemoteSSH, so it was not installed.')
  }
  const m = JSON.parse(body.toString('utf8')) as Partial<UpdateManifest>
  if (m.app !== APP_ID || m.version !== version || !m.files || typeof m.files !== 'object') {
    throw new Error(`The update's signature is not for RemoteSSH ${version}, so it was not installed.`)
  }
  return m as UpdateManifest
}

/** SHA-512 of a file, base64 (the form electron-builder uses). */
export function sha512(file: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha512')
    createReadStream(file)
      .on('data', (chunk) => hash.update(chunk))
      .on('error', reject)
      .on('end', () => resolve(hash.digest('base64')))
  })
}

/** Every downloaded file must be one of the signed packages. */
export async function checkFiles(files: string[], manifest: UpdateManifest): Promise<void> {
  if (!files.length) throw new Error('The update download is empty.')
  const signed = new Set(Object.values(manifest.files))
  for (const f of files) {
    if (!signed.has(await sha512(f))) throw new Error(`${basename(f)} is not signed by RemoteSSH, so it was not installed.`)
  }
}

/** Fetches the release's manifest + signature from `baseUrl` and checks the downloaded `files` against them. */
export async function verifyUpdate(
  baseUrl: string,
  version: string,
  files: string[],
  fetch: (url: string) => Promise<Response>,
): Promise<void> {
  const get = async (name: string): Promise<Buffer> => {
    const res = await fetch(`${baseUrl}/${name}`)
    if (!res.ok) throw new Error(`This update has no signature (${name}: HTTP ${res.status}), so it was not installed.`)
    return Buffer.from(await res.arrayBuffer())
  }
  const [body, sig] = await Promise.all([get(MANIFEST), get(`${MANIFEST}.sig`)])
  await checkFiles(files, checkManifest(body, sig.toString('utf8'), version))
}

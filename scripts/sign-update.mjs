#!/usr/bin/env node
// Signs a desktop release for the in-app updater:
//   UPDATE_SIGNING_KEY=<Ed25519 private key, PEM> node scripts/sign-update.mjs <dir> <app id> <version> <public key source>
// Writes <dir>/update-signatures.json ({app, version, files: {name: sha512 base64}} for every package in <dir>) and
// <dir>/update-signatures.json.sig (base64 Ed25519 signature of that file). Refuses to sign when the key does not belong
// to the public key in <public key source> (the app's UPDATE_PUBLIC_KEY), so a release can't ship that the apps reject.
// Run by the release workflow inside the `desktop-release` environment, which holds the key.
import { createHash, createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [dir, app, version, source] = process.argv.slice(2);
if (!dir || !app || !/^\d+\.\d+\.\d+$/.test(version ?? '') || !source) {
  console.error('usage: sign-update.mjs <dir> <app id> <X.Y.Z> <file with the public key>');
  process.exit(2);
}
if (!process.env.UPDATE_SIGNING_KEY) {
  console.error('::error::UPDATE_SIGNING_KEY is not set (a secret of the desktop-release environment)');
  process.exit(1);
}
const key = createPrivateKey(process.env.UPDATE_SIGNING_KEY);
const pem = readFileSync(source, 'utf8').match(/-----BEGIN PUBLIC KEY-----[\s\S]+?-----END PUBLIC KEY-----/)?.[0];
if (!pem) throw new Error(`no public key in ${source}`);
const expected = createPublicKey(pem).export({ type: 'spki', format: 'der' });
if (!createPublicKey(key).export({ type: 'spki', format: 'der' }).equals(expected)) {
  console.error(`::error::UPDATE_SIGNING_KEY does not match the public key in ${source}`);
  process.exit(1);
}

const PACKAGE = /\.(exe|AppImage|deb|zip|dmg|pkg|tar\.gz)$/;
const files = {};
for (const name of readdirSync(dir).sort()) {
  if (PACKAGE.test(name)) files[name] = createHash('sha512').update(readFileSync(join(dir, name))).digest('base64');
}
if (!Object.keys(files).length) throw new Error(`no packages in ${dir}`);

const body = Buffer.from(JSON.stringify({ app, version, files }, null, 2) + '\n');
const signature = sign(null, body, key);
if (!verify(null, body, createPublicKey(pem), signature)) throw new Error('signature check failed');
writeFileSync(join(dir, 'update-signatures.json'), body);
writeFileSync(join(dir, 'update-signatures.json.sig'), signature.toString('base64') + '\n');
console.log(`Signed ${Object.keys(files).length} packages of ${app} ${version}:`);
for (const name of Object.keys(files)) console.log(`  ${name}`);

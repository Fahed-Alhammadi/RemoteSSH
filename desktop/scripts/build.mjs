// Bundles the main process and preload with esbuild, then the renderer with Vite, into out/.
import { copyFileSync, mkdirSync, rmSync } from 'node:fs'
import { build as esbuild } from 'esbuild'
import { build as vite } from 'vite'

const production = process.env.NODE_ENV !== 'development'
rmSync('out', { recursive: true, force: true })
mkdirSync('out', { recursive: true })

const common = {
  bundle: true,
  platform: 'node',
  format: 'cjs',
  target: 'node22',
  sourcemap: !production,
  minify: production,
  logLevel: 'warning',
  // Runtime dependencies stay in node_modules (ssh2 has optional native add-ons).
  external: ['electron', 'ssh2', 'basic-ftp'],
}
await esbuild({ ...common, entryPoints: ['src/main/main.ts'], outfile: 'out/main.js' })
await esbuild({ ...common, entryPoints: ['src/preload/preload.ts'], outfile: 'out/preload.js' })
await vite({ configFile: 'vite.config.mts', logLevel: 'warn' })
copyFileSync('../assets/icon.png', 'out/icon.png')
copyFileSync('../assets/icon.png', 'out/renderer/icon.png')
console.log('Built to out/')

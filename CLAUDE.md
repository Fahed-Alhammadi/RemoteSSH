# RemoteSSH

## Overview
SFTP/FTP/FTPS client with a dual-pane browser, site manager, transfer queue and message log. Two apps share one
feature set and one `.remotessh` site file format: a native SwiftUI app (`macos/`) and an Electron app for Windows
and Linux (`desktop/`). It is a clean-room FileZilla-style client; no FileZilla code is used. Public repo (github.com/Fahed-Alhammadi/RemoteSSH, MIT): keep it
free of personal data (no real hosts, users, keys or local paths in code, tests or docs).

## Structure
- `assets/icon.png` — shared 1024px app icon: ink squircle, teal→cyan sync ring around a `>_` prompt (regenerate with `swift scripts/make-icon.swift assets/icon.png`; drawn shapes only, no SF Symbols or fonts)
- `scripts/` — `test-servers.sh` (throwaway sshd + pyftpdlib, exports `RSSH_*` and then runs a command), `test-ftpserver.py`, `make-icon.swift`
- `.github/workflows/` — `ci.yml` (desktop on Ubuntu/Windows, Swift on macOS), `release.yml` (tag `v*` → draft release with all packages)
- `macos/` — SwiftPM package:
  - `Sources/CCurl` — libcurl shim. `Sources/CRSAShim` — BoringSSL RSA prototypes.
  - `Sources/RemoteSSHCore/` — engine and storage (`Models/`, `Engine/`, `Storage/`, `Queue/`, `Update/ReleaseCheck` for the GitHub latest-release lookup).
  - `Sources/RemoteSSH/` — SwiftUI app: `Support/` (state, transfers, `Updater`: download → SHA-256/bundle-ID/codesign check → swap bundle via detached shell → relaunch) and `Views/` (`Theme.swift`: design tokens, `PaneChip`, `StatusDot`).
  - `Tests/` — tests. `scripts/` — `build-app.sh`, `integration-test.sh`.
- `desktop/` — Electron app:
  - `src/shared/` — `types.ts` (mirrors the Swift Codable models), `site.ts` (quickconnect parsing), `util.ts`, `api.ts` (IPC contract).
  - `src/main/` — main process:
    - `main.ts` — window and menu.
    - `controller.ts` — IPC handlers, connection, prompts, log batching, `EditWatcher`.
    - `transfers.ts` — `TransferManager`.
    - `updater.ts` — GitHub-release updates (electron-updater for NSIS/AppImage/deb; portable/tar.gz only link to the release page).
    - `engine/` — `session.ts` (interfaces, `Throttle`, `Mutex`), `sftpSession.ts` (ssh2), `ftpSession.ts` (basic-ftp), `localFS.ts`.
    - `store/` — `siteStore` (safeStorage secrets), `siteArchive`, `knownHosts`, `settingsStore` (+ `QueueStore`).
  - `src/preload/preload.ts` — exposes `window.remotessh`.
  - `src/renderer/` — React UI: `App.tsx` and `components/` (FilePane, LogQueue, SiteManager, Prompts, SettingsDialog, FileIcon, ui).
  - `tests/` — `core.test.ts` (unit) and `integration.test.ts` (live, env-gated).
  - `scripts/build.mjs` — esbuild for main/preload and Vite for the renderer → `out/`.

## Tech Stack
- **macOS:** Swift 6.4 (language mode 5), SwiftUI/AppKit, macOS 14+.
  - System libcurl (FTP/FTPS).
  - Citadel **exact 0.12.0** + Joannis/swift-nio-ssh (SFTP); swift-collections capped below 1.5.
  - SQLite3 and the Keychain.
- **Desktop:** Electron 44, React 19, TypeScript 7, Vite 8, esbuild, Vitest 5, electron-builder 26, lucide-react icons.
  - ssh2 (SFTP) and basic-ftp (FTP/FTPS, passive only).
  - Optional native add-ons (cpu-features, ssh2 crypto binding) are denied in `allowScripts` and excluded from packages.

## Commands
- Desktop (`cd desktop`):
  - `npm ci`, then `npm start` to run, `npm run build` (typecheck and bundle) or `npm run typecheck`.
  - Tests: `npm test` (unit), `npm run test:live` (live FTP/FTPES/SFTP).
  - Packages: `npm run dist:linux`, `npm run dist:win` (both work from macOS too).
  - Screenshot (dev build only): `REMOTESSH_CAPTURE=shot.png npx electron . --user-data-dir=/tmp/x`.
- macOS (`cd macos`):
  - App: `./scripts/build-app.sh` → `dist/RemoteSSH.app`.
  - All tests, live included: `./scripts/integration-test.sh`.
  - Command Line Tools only: build with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build`, and for `swift test` add `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.
- Lint: none. Both apps must build warning-free (`tsc` is strict, with `noUnused*`).

## Conventions
- **Shared formats.** `.remotessh` is `{format:"remotessh.sites", version:1, exportedAt, sites, passwords?}`.
  - Passwords are keyed by the uppercase UUID string.
  - `exportedAt` is ISO 8601 without fractional seconds, because Swift rejects them.
  - Site field names and enum values are identical in Swift and TS.
- **UI-agnostic engines.** Questions go through `SessionPrompter` (Swift) or `Prompter.ask(PromptRequest)` (TS); the renderer queues prompts.
- **Sessions.** One session is one connection. Transfers use per-site pooled sessions, separate from the browse session.
  - basic-ftp allows one command at a time, so `FTPSession` serialises through `Mutex`.
- **Hot paths.**
  - Log lines are batched: 50 ms in TS, `LogBuffer` in Swift.
  - Queue updates are coalesced to 10 Hz.
  - SFTP uses fastGet/fastPut when there is no resume or limit.
  - Tables are virtualised (`useVirtualRows`), and icons are pure lookups.
- **Security.**
  - FTPS checks certificates before login.
  - Electron runs with `contextIsolation` and `sandbox`, a CSP, and no navigation.
  - On Linux, the `basic_text` safeStorage backend counts as "no keyring", so passwords are not saved.
- **Icons.** SF Symbols on macOS, lucide-react on desktop (stroke 1.75; 18px toolbar, 15–16px rows/menus). No FileZilla branding.
- **Design ("Ink & Teal").** Tokens live in `styles.css` `:root` (light + dark) and `Theme.swift`; keep them in sync and never hard-code hex in components. Accent teal-700 `#0F766E` (light) / teal-400 `#2DD4BF` with dark text (dark). Text pairs meet WCAG AA. Log, panes and queue are 12px-radius cards on `--bg`; state is never colour-only (status dot + text). Motion 120–180 ms, disabled under `prefers-reduced-motion`. macOS stays native (system controls, `.tint(Theme.accent)`).
- **Pins.** Citadel is pinned to exactly 0.12.0 (`RSASHA2.swift` reads a Citadel internal). On macOS 27, SDK 26.5 is needed with CLT only.
- **Updates.** Both apps read `releases/latest` of `Fahed-Alhammadi/RemoteSSH` (drafts are invisible until published). The release workflow sets the version from the tag (`npm version`, `VERSION=` for `build-app.sh`) and uploads `latest*.yml` + `*.blockmap` for electron-updater. Mac update toggle is UserDefaults `RemoteSSH.checkForUpdates` (kept out of `AppSettings`, whose synthesized Codable would drop old settings on a new key).
- **Linux .deb.** `build.deb.depends` must list the Electron runtime libraries explicitly (the defaults miss libgbm1/libasound2).

## Change Log
- 2026-10-16: UI and icon redesign ("Ink & Teal"). New app icon. Desktop: token-based stylesheet with light/dark, card layout, one-row pane headers, row hover, status dot, empty states, reduced-motion. macOS: `Theme.swift`, brand tint, pane chips, status dot and a Site Manager action in the empty remote pane.
- 2026-10-14: Over-the-air updates from GitHub releases in both apps (startup check + "Check for Updates…" menu + setting). Fixed release builds ignoring the tag version (desktop was always 1.0.0; Mac used `git describe` on a shallow clone).
- 2026-10-14: GitHub Actions bumped to Node 24 versions (checkout/setup-node/upload-artifact v7, download-artifact v8, action-gh-release v3).
- 2026-10-14: MIT `LICENSE`; homepage/author/maintainer set to GitHub user Fahed-Alhammadi (noreply address). Git repo initialised with a repo-local noreply commit email.
- 2026-10-14: Added the Windows/Linux Electron app (`desktop/`) with feature parity, a shared `.remotessh` format and live tests that run on macOS and Linux. Turned the repo into a monorepo (`macos/`, `desktop/`, shared `assets/` and `scripts/`). Added GitHub CI/release workflows. Removed private data for publishing: the FileRemote migration code, the committed test private key (now generated at runtime) and the SF Symbols in the app icon. `.remotessh` passwords are now a string-keyed JSON object.
- 2026-10-14: Renamed FileRemote → RemoteSSH. Replaced the FileZilla import with `.remotessh` import/export. New icons, `AppModel` split up, and performance work (batched log, throttled progress, FTP SIZE).
- 2026-10-14: Fixed SFTP key login for 16-byte-padded OpenSSH keys. Initial macOS implementation.

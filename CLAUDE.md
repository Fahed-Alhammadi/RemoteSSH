# RemoteSSH

## Overview
SFTP/FTP/FTPS client with a dual-pane browser, site manager, transfer queue and message log. Two apps share one
feature set and one `.remotessh` site file format: a native SwiftUI app (`macos/`) and an Electron app for Windows
and Linux (`desktop/`). It is a clean-room FileZilla-style client; no FileZilla code is used. Public repo (github.com/Fahed-Alhammadi/RemoteSSH, MIT): keep it
free of personal data (no real hosts, users, keys or local paths in code, tests or docs).

## Structure
- `assets/icon.png` — shared 1024px app icon (regenerate with `swift scripts/make-icon.swift assets/icon.png`; drawn shapes only, no SF Symbols or fonts)
- `scripts/` — `test-servers.sh` (throwaway sshd + pyftpdlib, exports `RSSH_*` and then runs a command), `test-ftpserver.py`, `make-icon.swift`
- `.github/workflows/` — `ci.yml` (desktop on Ubuntu/Windows, Swift on macOS), `release.yml` (tag `v*` → draft release with all packages)
- `macos/` — SwiftPM package:
  - `Sources/CCurl` — libcurl shim. `Sources/CRSAShim` — BoringSSL RSA prototypes.
  - `Sources/RemoteSSHCore/` — engine and storage (`Models/`, `Engine/`, `Storage/`, `Queue/`).
  - `Sources/RemoteSSH/` — SwiftUI app: `Support/` (state and transfers) and `Views/`.
  - `Tests/` — tests. `scripts/` — `build-app.sh`, `integration-test.sh`.
- `desktop/` — Electron app:
  - `src/shared/` — `types.ts` (mirrors the Swift Codable models), `site.ts` (quickconnect parsing), `util.ts`, `api.ts` (IPC contract).
  - `src/main/` — main process:
    - `main.ts` — window and menu.
    - `controller.ts` — IPC handlers, connection, prompts, log batching, `EditWatcher`.
    - `transfers.ts` — `TransferManager`.
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
- **Icons.** SF Symbols on macOS, lucide-react on desktop. No FileZilla branding.
- **Pins.** Citadel is pinned to exactly 0.12.0 (`RSASHA2.swift` reads a Citadel internal). On macOS 27, SDK 26.5 is needed with CLT only.
- **Linux .deb.** `build.deb.depends` must list the Electron runtime libraries explicitly (the defaults miss libgbm1/libasound2).

## Change Log
- 2026-10-14: MIT `LICENSE`; homepage/author/maintainer set to GitHub user Fahed-Alhammadi (noreply address). Git repo initialised with a repo-local noreply commit email.
- 2026-10-14: Added the Windows/Linux Electron app (`desktop/`) with feature parity, a shared `.remotessh` format and live tests that run on macOS and Linux. Turned the repo into a monorepo (`macos/`, `desktop/`, shared `assets/` and `scripts/`). Added GitHub CI/release workflows. Removed private data for publishing: the FileRemote migration code, the committed test private key (now generated at runtime) and the SF Symbols in the app icon. `.remotessh` passwords are now a string-keyed JSON object.
- 2026-10-14: Renamed FileRemote → RemoteSSH. Replaced the FileZilla import with `.remotessh` import/export. New icons, `AppModel` split up, and performance work (batched log, throttled progress, FTP SIZE).
- 2026-10-14: Fixed SFTP key login for 16-byte-padded OpenSSH keys. Initial macOS implementation.

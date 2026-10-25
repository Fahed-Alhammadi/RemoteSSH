<p align="center"><img src="assets/icon.png" width="128" alt="RemoteSSH icon"></p>

<h1 align="center">RemoteSSH</h1>

<p align="center">A fast, modern <b>SFTP, FTP and FTPS</b> file transfer client for <b>macOS, Windows and Linux</b>.</p>

RemoteSSH has two code bases that share one feature set and one site file format. Each platform is built and released on its own, with its own version:

| Platform | App | Folder | Release tag |
| --- | --- | --- | --- |
| macOS 14+ | Native SwiftUI app | [`macos/`](macos) | `macos-v1.2.3` |
| Windows 10+ (x64, arm64) | Electron + React app from [`electron/`](electron), packaged by [`windows/`](windows) | [`windows/`](windows) | `windows-v1.2.3` |
| Linux (x64, arm64) | Electron + React app from [`electron/`](electron), packaged by [`linux/`](linux) | [`linux/`](linux) | `linux-v1.2.3` |

## Features

- **Connect:** a Quickconnect bar (`sftp://user@host:port/path`) and a Site Manager with folders, logon types (anonymous, normal, ask for password, key file) and default folders.
- **Secure storage:** saved passwords go into the system keychain (macOS Keychain, Windows DPAPI, or the Secret Service/KWallet on Linux). If no keyring is available, RemoteSSH asks for the password instead of saving it in plain text.
- **SFTP:** password or key-file login with Ed25519 and RSA keys (rsa-sha2-256/512), including passphrase-protected keys. Host keys are checked against SHA-256 fingerprints, and you are warned if a key changes.
- **FTP/FTPS:** explicit or implicit TLS. Before any password is sent, you are asked about certificates that can't be verified.
- **Browsing:** local and remote panes side by side, with sortable columns, a filter, file-type icons, hidden files, directory comparison, synchronized browsing, and drag & drop between panes and from your file manager.
- **File operations:** create, rename, delete (recursively), change permissions, and View/Edit (open a remote file locally and upload it again when you save).
- **Transfer queue:** parallel transfers, queued/failed/done tabs, automatic retries, resume, a choice of what to do when a file already exists, and speed limits. The queue is kept across restarts.
- **Automatic updates:** checks GitHub for a new release at startup (or *Check for Updates…* in the menu), then downloads, installs and relaunches. The Windows portable `.exe` and Linux `.tar.gz` builds only open the download page.
- **Import/export:** `File → Export Sites…` writes a `.remotessh` file and `File → Import from RemoteSSH…` reads one. The same file works on every platform. Passwords are only included if you choose to.

## Download

Prebuilt packages are attached to the [GitHub releases](../../releases). Each release is for one platform:

- **Windows:** `RemoteSSH-x.y.z-win-x64.exe` (installer), `-win-arm64.exe`, or `RemoteSSH-x.y.z-portable.exe`.
- **Linux:** `.AppImage`, `.deb` (Debian/Ubuntu) or `.tar.gz`, for x64 and arm64.
- **macOS:** `RemoteSSH-x.y.z-macos.zip`.

The macOS app is signed with a Developer ID and notarized by Apple, so it opens without a warning. The Windows builds are not code-signed: SmartScreen shows a warning the first time, so click *More info → Run anyway*.

## Build from source

### Windows and Linux (`electron/`)

You need Node.js 22 or later. The shared Electron app lives in `electron/`; `windows/` and `linux/` hold each platform's packaging settings (`electron-builder.json`) and receive its packages in `dist/`.

```bash
cd electron
npm ci
npm start              # build and run
npm test               # unit tests
npm run test:live      # + live FTP/FTPS/SFTP tests (Linux/macOS: needs sshd, python3, openssl)
npm run dist:linux     # → ../linux/dist/*.AppImage, *.deb, *.tar.gz
npm run dist:win       # → ../windows/dist/*.exe (works from Windows, macOS or Linux)
```

### macOS (`macos/`)

You need macOS 14 or later with Xcode or the Xcode Command Line Tools.

```bash
cd macos
./scripts/build-app.sh          # → dist/RemoteSSH.app (ad-hoc signed)
./scripts/integration-test.sh   # unit tests + live FTP/FTPES/SFTP tests against throwaway local servers
```

To sign and notarize a build yourself (needs a Developer ID Application certificate and an App Store Connect API key):

```bash
SIGN_IDENTITY="Developer ID Application" ./scripts/build-app.sh
APPLE_API_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8 APPLE_API_ISSUER_ID=<issuer-id> ./scripts/notarize.sh
```

## Where data is stored

| | Sites, known hosts, queue, settings | Passwords |
| --- | --- | --- |
| macOS | `~/Library/Application Support/RemoteSSH/` | Keychain (service `RemoteSSH`) |
| Windows | `%APPDATA%\RemoteSSH\` | `secrets.json`, encrypted with DPAPI |
| Linux | `~/.config/RemoteSSH/` | `secrets.json`, encrypted using the Secret Service or KWallet |

## Releasing

Each platform has its own workflow and tag. Pushing the tag builds that platform's packages, sets the version from the tag and publishes them as a GitHub release, so the apps can update right away:

| Tag | Workflow |
| --- | --- |
| `macos-v1.2.3` | [`.github/workflows/macos.yml`](.github/workflows/macos.yml) |
| `windows-v1.2.3` | [`.github/workflows/windows.yml`](.github/workflows/windows.yml) |
| `linux-v1.2.3` | [`.github/workflows/linux.yml`](.github/workflows/linux.yml) |

Each app only updates itself from releases with its own tag prefix. A signed Mac app only accepts an update signed by the same Developer ID team. The same workflows also build and test their platform on every push and pull request that touches its code.

## License

[MIT](LICENSE) © Fahed Alhammadi

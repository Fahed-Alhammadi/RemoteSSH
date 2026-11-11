# Security Policy

RemoteSSH handles passwords, private keys and connections to your servers, so security reports are taken seriously. Thank you for helping keep its users safe.

## Supported versions

Only the [latest release](https://github.com/Fahed-Alhammadi/RemoteSSH/releases/latest) receives security fixes. Every platform (macOS, Windows, Linux) shares one version number, and fixes ship as a new release for all of them. The apps offer to install new releases themselves, so please update before reporting.

| Version | Supported |
| --- | --- |
| Latest release | ✅ |
| Older releases | ❌ |

## Reporting a vulnerability

**Please do not open a public issue, discussion or pull request for a security problem.**

Report it privately through GitHub instead:

1. Go to the repository's [Security tab](https://github.com/Fahed-Alhammadi/RemoteSSH/security).
2. Choose **Report a vulnerability**.
3. Fill in the form. Only the maintainer can see it.

Helpful details:

- The app and version (*About RemoteSSH*), and your operating system.
- The protocol involved (SFTP, FTP, FTPS) and any relevant site settings.
- Steps to reproduce, a proof of concept, or a minimal test server setup.
- What an attacker could achieve, and under which conditions (for example a malicious server, a network attacker, or a hostile file name).

Please leave out real passwords, private keys and server addresses. If a reproduction needs a server, a local one is ideal: `scripts/test-servers.sh` starts throwaway SFTP and FTP servers.

## What to expect

RemoteSSH is maintained by one person in their spare time, so these are goals rather than guarantees:

- An acknowledgement within **7 days**.
- An assessment, and a fix plan if the report is confirmed, within **30 days**.
- A fixed release as soon as practical, followed by a published [security advisory](https://github.com/Fahed-Alhammadi/RemoteSSH/security/advisories). You will be credited unless you prefer not to be.

Please give us a reasonable chance to release a fix before disclosing the problem publicly.

## Scope

In scope:

- The macOS app (`macos/`) and the Windows/Linux Electron app (`electron/`).
- Host key and certificate checks, TLS handling and downgrade protection.
- Storage of passwords, known hosts, trusted certificates and `.remotessh` site files.
- Anything a malicious server can cause: file names, listings, terminal output, transfers that write outside the chosen folder.
- The update mechanism and the release workflows in `.github/workflows/`.
- The project website in `Website/`.

Out of scope:

- Vulnerabilities in the servers you connect to, or in their configuration.
- Attacks that need an already compromised local account or administrator access to your computer.
- Plain FTP sending data unencrypted. That is how the protocol works, and RemoteSSH points out sites that use it.
- The known limitations listed below.
- Problems in third-party dependencies that don't affect RemoteSSH. If they do, a report here is welcome; please also report them upstream.

## Known limitations

- **Windows builds are not code-signed.** Windows shows *Unknown publisher*, and in-app updates on Windows are checked against the SHA-512 hash published in the same release rather than a code signature. The release page lists each file's SHA-256 checksum for manual verification.
- **Linux without a keyring.** When no Secret Service or KWallet is available, passwords are not saved at all, and RemoteSSH asks for them when you connect.

See the [Security section of the README](README.md#security) for how RemoteSSH protects connections and stored data.

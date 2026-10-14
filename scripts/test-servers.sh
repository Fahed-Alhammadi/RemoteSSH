#!/usr/bin/env bash
# Starts throwaway local servers, runs the given command with RSSH_* variables pointing at them,
# then tears everything down:
#   - OpenSSH sshd (user-level, 127.0.0.1:2222) with an ed25519 key and a passphrase-protected RSA key
#   - pyftpdlib FTP with optional explicit TLS (127.0.0.1:2121) and a self-signed certificate
# Needs: sshd, ssh-keygen, openssl, python3, curl. Usage: scripts/test-servers.sh <command...>
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d)
cleanup() { [ -f "$W/sshd.pid" ] && kill "$(cat "$W/sshd.pid")" 2>/dev/null; [ -n "${FTP_PID:-}" ] && kill "$FTP_PID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

SSHD=$(command -v sshd || echo /usr/sbin/sshd)
ssh-keygen -q -t ed25519 -N "" -f "$W/hostkey"
ssh-keygen -q -t ed25519 -N "" -f "$W/userkey"
ssh-keygen -q -t rsa -b 3072 -N "pass phrase" -f "$W/userkey_rsa"
cat "$W/userkey.pub" "$W/userkey_rsa.pub" > "$W/authorized_keys"
cat > "$W/sshd_config" <<CFG
Port 2222
ListenAddress 127.0.0.1
HostKey $W/hostkey
AuthorizedKeysFile $W/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile $W/sshd.pid
Subsystem sftp internal-sftp
CFG
"$SSHD" -f "$W/sshd_config"

python3 -m venv "$W/venv"
"$W/venv/bin/pip" install -q pyftpdlib pyopenssl
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/ftp.key" -out "$W/ftp.crt" -days 1 -subj "/CN=localhost" 2>/dev/null
mkdir -p "$W/ftproot"
"$W/venv/bin/python" -I "$ROOT/scripts/test-ftpserver.py" "$W/ftproot" "$W/ftp.crt" "$W/ftp.key" &
FTP_PID=$!
for _ in $(seq 20); do curl -s -o /dev/null --user tester:secret ftp://127.0.0.1:2121/ && break; sleep 0.5; done

export RSSH_FTP_HOST=127.0.0.1 RSSH_FTP_PORT=2121 RSSH_FTP_USER=tester RSSH_FTP_PASS=secret
export RSSH_SFTP_HOST=127.0.0.1 RSSH_SFTP_PORT=2222 RSSH_SFTP_USER="$(id -un)" RSSH_SFTP_KEY="$W/userkey"
export RSSH_SFTP_RSA_KEY="$W/userkey_rsa" RSSH_SFTP_RSA_PASS="pass phrase"
"$@"

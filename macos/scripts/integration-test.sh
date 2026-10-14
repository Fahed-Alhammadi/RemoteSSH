#!/usr/bin/env bash
# Unit tests + live FTP/FTPES/SFTP tests against throwaway local servers (see ../../scripts/test-servers.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${SDKROOT:-}" ] && ! xcode-select -p | grep -q Xcode.app; then
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$SDK" ] && export SDKROOT="$SDK"
fi
PLUGIN_FLAGS=()
[ -d /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing ] && \
  PLUGIN_FLAGS=(-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing)

../scripts/test-servers.sh swift test "${PLUGIN_FLAGS[@]}"

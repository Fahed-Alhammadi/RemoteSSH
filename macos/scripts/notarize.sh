#!/usr/bin/env bash
# Notarizes dist/RemoteSSH.app (built with SIGN_IDENTITY set), staples the ticket and checks it with Gatekeeper.
# Needs an App Store Connect API key (Users and Access → Integrations → Keys):
#   APPLE_API_KEY_PATH   the AuthKey_XXXXXXXXXX.p8 file
#   APPLE_API_ISSUER_ID  the Issuer ID shown above the list of keys
#   APPLE_API_KEY_ID     the Key ID (optional; taken from the AuthKey_<id>.p8 file name)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/RemoteSSH.app
: "${APPLE_API_KEY_PATH:?Set APPLE_API_KEY_PATH to the .p8 file}"
: "${APPLE_API_ISSUER_ID:?Set APPLE_API_ISSUER_ID}"
KEY_ID=${APPLE_API_KEY_ID:-$(basename "$APPLE_API_KEY_PATH" .p8 | sed -n 's/^AuthKey_//p')}
[ -n "$KEY_ID" ] || { echo "Set APPLE_API_KEY_ID" >&2; exit 1; }
AUTH=(--key "$APPLE_API_KEY_PATH" --key-id "$KEY_ID" --issuer "$APPLE_API_ISSUER_ID")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --keepParent "$APP" "$WORK/RemoteSSH.zip"

echo "Submitting to Apple's notary service (usually a few minutes)…"
xcrun notarytool submit "$WORK/RemoteSSH.zip" "${AUTH[@]}" --wait --timeout 30m --output-format json > "$WORK/result.json"
STATUS=$(plutil -extract status raw "$WORK/result.json")
ID=$(plutil -extract id raw "$WORK/result.json")
if [ "$STATUS" != "Accepted" ]; then
  echo "Notarization finished with status: $STATUS" >&2
  xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  exit 1
fi

# Apple's ticket servers occasionally drop the connection, so stapling gets a few tries.
for attempt in 1 2 3 4; do
  xcrun stapler staple "$APP" && break
  [ "$attempt" = 4 ] && exit 1
  echo "Stapling failed (attempt $attempt), retrying in 20 s…" >&2
  sleep 20
done
spctl --assess --type execute -vv "$APP"
echo "Notarized $APP"

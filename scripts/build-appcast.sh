#!/bin/bash
#
# Signs a DMG for Sparkle and writes build/appcast.xml, the feed the app checks for updates.
#
#   scripts/build-appcast.sh <dmg> [release-notes-file]
#
# The feed lists only this release: it's attached to the release itself, and the app reads it from
# releases/latest, so the newest release always describes itself.
#
# The EdDSA private key comes from $SPARKLE_PRIVATE_KEY (in CI), or else from your keychain, where
# Sparkle's generate_keys saved it. Run scripts/build-dmg.sh first: it fetches Sparkle's tools.
# Written for the bash 3.2 that ships with macOS.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO="alexisbcz/hypercode"
MIN_MACOS="26.0"

dmg=${1:?usage: scripts/build-appcast.sh <dmg> [release-notes-file]}
notes=${2:-}
[[ -f "$dmg" ]] || {
  echo "Error: $dmg doesn't exist." >&2
  exit 1
}
version=$(basename "$dmg" .dmg)
version=${version#Hypercode-}

sign_update=build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
[[ -x "$sign_update" ]] || {
  echo "Error: $sign_update is missing; run scripts/build-dmg.sh first." >&2
  exit 1
}

# Prints: sparkle:edSignature="..." length="..."
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$dmg")
else
  signature=$("$sign_update" "$dmg")
fi

# Plain text, escaped for XML; Sparkle shows it in the update window.
description=""
if [[ -n "$notes" && -s "$notes" ]]; then
  escaped=$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$notes")
  description="<description sparkle:format=\"plain-text\">$escaped</description>"
fi

cat >build/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Hypercode</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Hypercode $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/v$version</link>
      $description
      <enclosure url="https://github.com/$REPO/releases/download/v$version/$(basename "$dmg")" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
EOF

echo "Wrote build/appcast.xml for $version"

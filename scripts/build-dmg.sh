#!/bin/bash
#
# Builds Hypercode in Release and packs it into build/Hypercode-<version>.dmg,
# next to a .sha256 file.
#
#   scripts/build-dmg.sh [version]
#
# The version (a leading "v" is dropped) defaults to MARKETING_VERSION in project.yml.
# Written for the bash 3.2 that ships with macOS.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Hypercode"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

version=${1:-$(awk -F'"' '/MARKETING_VERSION/ { print $2 }' project.yml)}
version=${version#v}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Error: '$version' isn't a version like 1.2.3." >&2
  exit 1
}

# MLX compiles Metal shaders, and Xcode ships the Metal toolchain as a separate download.
if ! xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -q 'Status: installed'; then
  xcodebuild -downloadComponent MetalToolchain
fi

xcodegen generate --quiet
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath build \
  -quiet \
  MARKETING_VERSION="$version" \
  build

app="build/Build/Products/Release/$APP_NAME.app"
[[ -d "$app" ]] || {
  echo "Error: the build finished but $app is missing." >&2
  exit 1
}
[[ -x "$app/Contents/Resources/bin/hypercode" ]] || {
  echo "Error: the hypercode command line tool is missing from $app." >&2
  exit 1
}
built=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$built" == "$version" ]] || {
  echo "Error: the app says $built, expected $version." >&2
  exit 1
}
codesign --verify --deep --strict "$app"

# The usual drag-to-install layout: the app next to a shortcut to /Applications.
stage=build/dmg
dmg="build/$APP_NAME-$version.dmg"
rm -rf "${stage:?}" "$dmg"
mkdir -p "$stage"
ditto "$app" "$stage/$APP_NAME.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
rm -rf "${stage:?}"

(cd build && shasum -a 256 "$(basename "$dmg")" >"$(basename "$dmg").sha256")

echo "Built $dmg"

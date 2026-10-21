#!/bin/bash
#
# Builds Hypercode from source and installs it into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/alexisbcz/hypercode/main/install.sh | bash
#
# Options (pass after `bash -s --` when piping):
#   --ref <branch|tag>   build another branch or tag (default: main)
#   --dir <path>         install somewhere else (default: /Applications, or ~/Applications)
#   --no-open            don't launch the app when done
#   --no-cli             don't link the `hypercode` command into your PATH
#   --uninstall          remove the app (from --dir, or both default places)
#
# Everything lives in main() so a half-downloaded script can't run.
# Written for the bash 3.2 that ships with macOS.

set -euo pipefail

APP_NAME="Hypercode"
APP_SLUG="hypercode"
BUNDLE_ID="dev.alexis.Hypercode"
REPO="alexisbcz/hypercode"
MIN_MACOS=26

if [[ -t 1 ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RESET=$'\033[0m'
else
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" RESET=""
fi

step() { printf '%s==>%s %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$*" "$RESET"; }
info() { printf '    %s%s%s\n' "$DIM" "$*" "$RESET"; }
warn() { printf '%sWarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# Runs a long command quietly with a spinner, and prints the end of its log if it fails.
run_logged() {
  local label=$1 log=$2
  shift 2
  "$@" >"$log" 2>&1 &
  local pid=$! frames='|/-\' i=0 start=$SECONDS
  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r    %s %s %s(%ds)%s' "${frames:i++%4:1}" "$label" "$DIM" $((SECONDS - start)) "$RESET"
      sleep 0.1
    done
    printf '\r\033[K'
  fi
  if ! wait "$pid"; then
    tail -n 40 "$log" >&2
    die "$label failed. Full log: $log"
  fi
  info "$label done in $((SECONDS - start))s"
}

quit_app() {
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  local tries=0
  while lsappinfo find "bundleid=$BUNDLE_ID" 2>/dev/null | grep -q ASN && ((tries++ < 50)); do
    sleep 0.2
  done
}

usage() {
  cat <<EOF
Builds $APP_NAME from source and installs it.

Options:
  --ref <branch|tag>   build another branch or tag (default: main)
  --dir <path>         install somewhere else (default: /Applications, or ~/Applications)
  --no-open            don't launch the app when done
  --no-cli             don't link the hypercode command into your PATH
  --uninstall          remove the app (from --dir, or both default places)
EOF
}

default_install_dir() {
  if [[ -w /Applications ]]; then echo /Applications; else echo "$HOME/Applications"; fi
}

# Removes the app from each directory given.
uninstall() {
  local removed=0
  for d in "$@"; do
    if [[ -d "$d/$APP_NAME.app" ]]; then
      quit_app
      rm -rf "$d/$APP_NAME.app"
      step "Removed $d/$APP_NAME.app"
      for link in "$HOME/.local/bin/hypercode" /opt/homebrew/bin/hypercode /usr/local/bin/hypercode; do
        if [[ "$(readlink "$link" 2>/dev/null)" == "$d/$APP_NAME.app/"* ]] && rm -f "$link" 2>/dev/null; then
          step "Removed $link"
        fi
      done
      removed=1
    fi
  done
  if ((removed)); then
    info "Settings stay in ~/Library/Preferences/$BUNDLE_ID.plist; delete it for a clean slate."
  else
    info "$APP_NAME isn't installed."
  fi
}

check_system() {
  [[ "$(uname -s)" == Darwin ]] || die "$APP_NAME is a macOS app."
  [[ "$(uname -m)" == arm64 ]] || die "$APP_NAME needs a Mac with Apple silicon (its speech models run on MLX)."
  local version
  version=$(sw_vers -productVersion)
  ((${version%%.*} >= MIN_MACOS)) || die "$APP_NAME needs macOS $MIN_MACOS or later (this Mac runs $version)."
  info "macOS $version on Apple silicon"
}

# xcodebuild needs the full Xcode, and xcode-select often points at the Command Line Tools.
find_xcode() {
  local candidates=()
  [[ -n "${DEVELOPER_DIR:-}" ]] && candidates+=("$DEVELOPER_DIR")
  candidates+=("$(xcode-select -p 2>/dev/null || true)" /Applications/Xcode.app/Contents/Developer)
  while IFS= read -r app; do
    candidates+=("$app/Contents/Developer")
  done < <(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | sort -r)

  for dir in "${candidates[@]}"; do
    if [[ -n "$dir" && -x "$dir/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR=$dir
      info "$(xcodebuild -version | head -n 1) at ${dir%/Contents/Developer}"
      return
    fi
  done
  die "Xcode isn't installed. Get it from https://apps.apple.com/app/xcode/id497799835, open it once, then run this again."
}

# When piped from curl, stdin is the script, so sudo has to ask on the terminal.
have_tty() { (exec </dev/tty) 2>/dev/null; }

prepare_xcode() {
  if ! xcodebuild -license check >/dev/null 2>&1; then
    have_tty || die "Accept the Xcode license first: sudo xcodebuild -license accept"
    step "Accepting the Xcode license (needs your password)"
    sudo xcodebuild -license accept </dev/tty
  fi
  # Builds often work without these, so a missing terminal only earns a warning.
  if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    if have_tty; then
      step "Installing Xcode's first-launch components (needs your password)"
      sudo xcodebuild -runFirstLaunch </dev/tty || warn "Xcode's first-launch setup failed; trying the build anyway."
    else
      warn "Xcode's first-launch components aren't installed. If the build fails, run: sudo xcodebuild -runFirstLaunch"
    fi
  fi
  # MLX compiles Metal shaders, and Xcode ships the Metal toolchain as a separate download.
  if ! xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -q 'Status: installed'; then
    step "Downloading the Metal toolchain"
    xcodebuild -downloadComponent MetalToolchain
  fi
}

find_xcodegen() {
  if command -v xcodegen >/dev/null 2>&1; then
    XCODEGEN=$(command -v xcodegen)
  elif command -v brew >/dev/null 2>&1; then
    step "Installing XcodeGen with Homebrew"
    brew install --quiet xcodegen
    XCODEGEN=$(brew --prefix)/bin/xcodegen
  else
    step "Downloading XcodeGen"
    curl -fsSL -o "$WORK/xcodegen.zip" https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip
    unzip -q "$WORK/xcodegen.zip" -d "$WORK"
    XCODEGEN=$WORK/xcodegen/bin/xcodegen
  fi
  info "XcodeGen $("$XCODEGEN" --version 2>/dev/null | awk '{print $NF}')"
}

# Links `hypercode` (so `hypercode .` opens a folder) into a writable folder on PATH, as the app's
# Install 'hypercode' Command in PATH does. Anything by that name that isn't Hypercode's stays.
link_cli() {
  local app=$1 dir link
  for dir in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
    case ":$PATH:" in *":$dir:"*) ;; *) continue ;; esac
    [[ -d "$dir" && -w "$dir" ]] || continue
    link="$dir/hypercode"
    if [[ -e "$link" || -L "$link" ]] && [[ "$(readlink "$link")" != *.app/Contents/Resources/bin/hypercode ]]; then
      warn "$link already exists and isn't Hypercode's, so the command wasn't linked."
      return
    fi
    ln -sf "$app/Contents/Resources/bin/hypercode" "$link"
    info "Linked the hypercode command at $link; run \"hypercode .\" to open a folder."
    return
  done
  info "To open folders with \"hypercode .\", use Hypercode > Install 'hypercode' Command in PATH."
}

after_install() {
  local home=$HOME found=""
  for dir in "$home/.local/bin" "$home/.claude/local" /opt/homebrew/bin /usr/local/bin; do
    [[ -x "$dir/claude" ]] && found="$dir/claude" && break
  done
  if [[ -n "$found" ]]; then
    info "Claude Code found at $found"
  else
    warn "Hypercode runs the Claude Code CLI, which isn't installed. Install it with:"
    printf '\n    curl -fsSL https://claude.ai/install.sh | bash\n\n' >&2
  fi
}

main() {
  local ref=main dest="" open=1 cli=1 remove=0
  while (($#)); do
    case $1 in
      --ref) ref=${2:?--ref needs a branch or tag}; shift 2 ;;
      --dir) dest=${2:?--dir needs a path}; shift 2 ;;
      --no-open) open=0; shift ;;
      --no-cli) cli=0; shift ;;
      --uninstall) remove=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown option: $1 (try --help)" ;;
    esac
  done
  if ((remove)); then
    if [[ -n "$dest" ]]; then uninstall "$dest"; else uninstall /Applications "$HOME/Applications"; fi
    return
  fi
  dest=${dest:-$(default_install_dir)}

  printf '\n%sInstalling %s%s\n\n' "$BOLD" "$APP_NAME" "$RESET"

  step "Checking your Mac"
  check_system
  find_xcode
  prepare_xcode

  WORK=$(mktemp -d -t "$APP_SLUG-install")
  trap 'rm -rf "$WORK"' EXIT
  find_xcodegen

  step "Fetching the source ($ref)"
  git clone --quiet --depth 1 --branch "$ref" "https://github.com/$REPO.git" "$WORK/src" ||
    die "Couldn't clone $REPO at $ref."
  info "$(git -C "$WORK/src" log -1 --format='%h %s')"

  step "Building $APP_NAME"
  info "The first build fetches and compiles MLX, so it takes a few minutes."
  (cd "$WORK/src" && "$XCODEGEN" generate --quiet)
  # Keep the log outside $WORK so it survives a failed build.
  local log="${TMPDIR:-/tmp}/$APP_SLUG-build.log"
  run_logged "Compiling" "$log" xcodebuild \
    -project "$WORK/src/$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$WORK/build" \
    -quiet build
  local built="$WORK/build/Build/Products/Release/$APP_NAME.app"
  [[ -d "$built" ]] || die "The build finished but $APP_NAME.app is missing. Log: $log"

  step "Installing to $dest"
  mkdir -p "$dest"
  quit_app
  rm -rf "${dest:?}/$APP_NAME.app"
  ditto "$built" "$dest/$APP_NAME.app"
  xattr -dr com.apple.quarantine "$dest/$APP_NAME.app" 2>/dev/null || true
  rm -f "$log"

  after_install
  ((cli)) && link_cli "$dest/$APP_NAME.app"

  printf '\n%s%s is installed.%s It updates itself from new releases.\n\n' "$GREEN$BOLD" "$APP_NAME" "$RESET"
  ((open)) && open "$dest/$APP_NAME.app"
  return 0
}

main "$@"

#!/bin/bash
set -euo pipefail
umask 022
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

# Every output comes from this package. No user's Factory/login files are read.
/usr/bin/swift build -c release
BIN_DIR="$(/usr/bin/swift build -c release --show-bin-path)"
DIST="$ROOT/dist"
APP="$DIST/FactorySwitcher.app"
/bin/mkdir -p "$DIST"
if [ -L "$DIST" ] || [ -L "$APP" ]; then
  printf 'Refusing a symlinked output directory.\n' >&2
  exit 1
fi
if [ -e "$APP" ] && [ ! -f "$APP/Contents/Resources/.switcher-build-output" ]; then
  printf 'An unrecognized app already exists at %s. Move it aside before building.\n' "$APP" >&2
  exit 1
fi

STAGING="$(/usr/bin/mktemp -d "$DIST/.app-build.XXXXXX")"
STAGED_APP="$STAGING/FactorySwitcher.app"
/bin/mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
/bin/cp "$BIN_DIR/FactorySwitcher" "$STAGED_APP/Contents/MacOS/FactorySwitcher"
/bin/cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
/bin/cp "$ROOT/docs/USAGE.zh-CN.md" "$STAGED_APP/Contents/Resources/使用说明.md"
/bin/cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
printf 'FactorySwitcher generated build output\n' > "$STAGED_APP/Contents/Resources/.switcher-build-output"
/bin/chmod 755 "$STAGED_APP/Contents/MacOS/FactorySwitcher"
/bin/chmod 644 "$STAGED_APP/Contents/Info.plist" "$STAGED_APP/Contents/Resources/"*
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier local.FactorySwitcher "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP"
"$STAGED_APP/Contents/MacOS/FactorySwitcher" --smoke-test

# Preserve the prior generated build, rather than deleting files.
if [ -e "$APP" ]; then
  /bin/mkdir -p "$DIST/previous-builds"
  /bin/mv "$APP" "$DIST/previous-builds/FactorySwitcher-$(/bin/date +%Y%m%d-%H%M%S)-$$.app"
fi
/bin/mv "$STAGED_APP" "$APP"
/bin/rmdir "$STAGING"
printf '\nBuilt: %s\nNo live Factory account was accessed or changed.\n' "$APP"

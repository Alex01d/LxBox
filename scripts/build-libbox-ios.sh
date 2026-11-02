#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

REPO="https://github.com/Leadaxe/sing-box-lx.git"
VER="${1:-$(tr -d '[:space:]' < app/android/libbox.version)}"
DEST="$ROOT/app/ios/Frameworks"
WORK="${LXBOX_CORE_BUILD_DIR:-$HOME/Library/Caches/lxbox-core-build}"
CORE="$WORK/$VER"

if [ -d "$DEST/Libbox.xcframework" ] && [ -f "$DEST/.libbox.version" ] \
   && [ "$(cat "$DEST/.libbox.version")" = "$VER" ]; then
  echo "✓ Libbox.xcframework already $VER — skipping"
  exit 0
fi

echo "→ Core $VER"
rm -rf "$CORE"
mkdir -p "$WORK"
git clone -q --depth 1 --branch "$VER" "$REPO" "$CORE"
git -C "$CORE" submodule update --init --recursive --depth 1 \
  submodules/gvisor submodules/sing-tun submodules/utls submodules/wireguard-go

DESCRIBED="$(git -C "$CORE" describe --tags --exact-match)"
if [ "$DESCRIBED" != "$VER" ]; then
  echo "✗ git describe gives $DESCRIBED, pin is $VER" >&2
  exit 1
fi

GOV="$(tr -d '[:space:]' < "$CORE/go.version")"
TOOLS="$WORK/tools"
TARBALL="$GOV.darwin-arm64.tar.gz"
mkdir -p "$TOOLS"
if [ "$("$TOOLS/go/bin/go" env GOVERSION 2>/dev/null || true)" != "$GOV" ]; then
  echo "→ Toolchain $GOV"
  rm -rf "$TOOLS/go"
  curl -fsSL --retry 3 -o "$TOOLS/$TARBALL" "https://dl.google.com/go/$TARBALL"
  EXPECTED="$(curl -fsSL --retry 3 "https://dl.google.com/go/$TARBALL.sha256")"
  echo "$EXPECTED  $TOOLS/$TARBALL" | shasum -a 256 -c -
  tar -xzf "$TOOLS/$TARBALL" -C "$TOOLS"
  rm -f "$TOOLS/$TARBALL"
fi

export GOROOT="$TOOLS/go"
export GOPATH="$TOOLS/gopath"
export GOCACHE="$TOOLS/gocache"
export GOFLAGS="-modcacherw"
export GOTOOLCHAIN=local
export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"

cd "$CORE"
echo "→ gomobile"
make lib_install
echo "→ gomobile bind"
go run ./cmd/internal/build_libbox -target apple -platform ios

mkdir -p "$DEST"
rm -rf "$DEST/Libbox.xcframework" "$DEST/.libbox.version"
mv "$CORE/Libbox.xcframework" "$DEST/Libbox.xcframework"
printf '%s' "$VER" > "$DEST/.libbox.version"
echo "✅ app/ios/Frameworks/Libbox.xcframework ← $VER"

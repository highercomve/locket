#!/bin/sh
# Install Locket from a GitHub release, for this user (no root):
#
#   curl -fsSL https://raw.githubusercontent.com/highercomve/locket/main/scripts/install.sh | sh
#
# Linux (x86_64, aarch64):
#   ~/.local/bin/locket        the command line (static)
#   ~/.local/bin/locket-app    the desktop app (AppImage, updates itself),
#                              with its launcher entry and icons
# macOS (Apple silicon, Intel):
#   ~/.local/bin/locket        the command line
#   ~/Applications/Locket.app  the desktop app (Apple silicon only)
#
# Every file is checked against the release's SHA256SUMS before it is
# installed. The vault is never touched. Settings (environment variables,
# or the same as flags after `sh -s --`):
#
#   LOCKET_VERSION=0.2.0    --version 0.2.0   a release (default: the latest)
#   LOCKET_BIN_DIR=DIR      --bin-dir DIR     where the binaries go (~/.local/bin)
#   LOCKET_NO_APP=1         --no-app          only the command line
#   LOCKET_NO_DESKTOP=1     --no-desktop      Linux: no launcher entry or icons
#
#   curl -fsSL .../install.sh | sh -s -- --no-app
set -eu

repo="highercomve/locket"
version="${LOCKET_VERSION:-}"
bin_dir="${LOCKET_BIN_DIR:-$HOME/.local/bin}"
no_app="${LOCKET_NO_APP:-}"
no_desktop="${LOCKET_NO_DESKTOP:-}"
app_id="com.foreachdeveloper.locket"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
usage: install.sh [--version X.Y.Z] [--bin-dir DIR] [--no-app] [--no-desktop]

Installs Locket from a GitHub release for this user: the command line to
~/.local/bin/locket and the app (Linux: ~/.local/bin/locket-app, macOS:
~/Applications). Environment: LOCKET_VERSION, LOCKET_BIN_DIR,
LOCKET_NO_APP=1, LOCKET_NO_DESKTOP=1.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a value"; version="$2"; shift 2 ;;
    --version=*) version="${1#*=}"; shift ;;
    --bin-dir) [ $# -ge 2 ] || die "--bin-dir needs a value"; bin_dir="$2"; shift 2 ;;
    --bin-dir=*) bin_dir="${1#*=}"; shift ;;
    --no-app) no_app=1; shift ;;
    --no-desktop) no_desktop=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done
version="${version#v}"

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
  # The tag releases/latest redirects to (no API call, no rate limit).
  latest() { curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
  latest() { wget -q -S --spider "https://github.com/$repo/releases/latest" 2>&1 | sed -n 's/^ *[Ll]ocation: *//p' | tail -n1 | tr -d '\r'; }
else
  die "curl or wget is needed"
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "sha256sum or shasum is needed to check the download"
fi

os=$(uname -s)
case "$os" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) die "unsupported system: $os (on Windows, use install.ps1)" ;;
esac
arch=$(uname -m)
case "$arch" in
  x86_64|amd64) arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) die "unsupported CPU: $arch (Locket is built for x86_64 and aarch64)" ;;
esac
# A shell under Rosetta still reports x86_64 on an Apple silicon Mac.
if [ "$os" = macos ] && [ "$arch" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
  arch=aarch64
fi

if [ -z "$version" ]; then
  url=$(latest) || die "could not find the latest release"
  version="${url##*/tag/v}"
  case "$version" in
    ""|*/*) die "could not find the latest release (got: $url)" ;;
  esac
fi
case "$version" in
  *[!0-9A-Za-z.-]*) die "not a version: $version" ;;
esac
base="https://github.com/$repo/releases/download/v$version"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Locket $version for $arch $os"
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" || die "no release v$version (or no SHA256SUMS in it)"

# get <asset>: download into $tmp and check it against SHA256SUMS.
get() {
  want=$(awk -v f="$1" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/SHA256SUMS")
  [ -n "$want" ] || die "$1 is not in the v$version release"
  say "Downloading $1"
  fetch "$base/$1" "$tmp/$1" || die "could not download $1"
  [ "$(sha256 "$tmp/$1")" = "$want" ] || die "$1 does not match its SHA-256 in SHA256SUMS"
}

mkdir -p "$bin_dir"

# The command line.
cli="locket-$version-$arch-$os"
get "$cli"
chmod 755 "$tmp/$cli"
mv -f "$tmp/$cli" "$bin_dir/locket"
say "Installed the command line to $bin_dir/locket"

# The app.
if [ -z "$no_app" ]; then
  if [ "$os" = linux ]; then
    appimage="locket-app-$version-$arch.AppImage"
    get "$appimage"
    chmod 755 "$tmp/$appimage"
    mv -f "$tmp/$appimage" "$bin_dir/locket-app"
    say "Installed the app to $bin_dir/locket-app"

    if [ -z "$no_desktop" ]; then
      # The launcher entry and icons the AppImage carries (extracting needs no FUSE).
      if (cd "$tmp" && "$bin_dir/locket-app" --appimage-extract 'usr/share/*' >/dev/null 2>&1); then
        share="$tmp/squashfs-root/usr/share"
        data="${XDG_DATA_HOME:-$HOME/.local/share}"
        mkdir -p "$data/applications"
        sed "s|^Exec=.*|Exec=$bin_dir/locket-app|" "$share/applications/$app_id.desktop" > "$data/applications/$app_id.desktop"
        for icon in "$share"/icons/hicolor/*/apps/"$app_id".png; do
          [ -f "$icon" ] || continue
          size=$(basename "$(dirname "$(dirname "$icon")")")
          mkdir -p "$data/icons/hicolor/$size/apps"
          cp -f "$icon" "$data/icons/hicolor/$size/apps/$app_id.png"
        done
        command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$data/applications" 2>/dev/null || true
        command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q "$data/icons/hicolor" 2>/dev/null || true
        say "Installed the launcher entry (Locket) and icons"
      else
        say "note: could not read the launcher entry from the AppImage; skipped it"
      fi
    fi
    if ! command -v fusermount >/dev/null 2>&1 && ! command -v fusermount3 >/dev/null 2>&1; then
      say "note: the AppImage needs FUSE to run: install the fuse3 package (or use the .deb / .rpm)"
    fi
  elif [ "$arch" = aarch64 ]; then
    bundle="locket-app-$version-macos-arm64.app.tar.gz"
    get "$bundle"
    mkdir -p "$tmp/app"
    tar -xzf "$tmp/$bundle" -C "$tmp/app"
    app=$(find "$tmp/app" -maxdepth 1 -name '*.app' | head -n1)
    [ -n "$app" ] || die "$bundle has no .app in it"
    name=$(basename "$app")
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$name"
    mv "$app" "$HOME/Applications/$name"
    say "Installed the app to ~/Applications/$name"
  else
    say "note: the macOS app is built for Apple silicon only; installed the command line"
  fi
fi

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) say "note: $bin_dir is not on your PATH; add it to run 'locket' by name:"
     say "  export PATH=\"$bin_dir:\$PATH\"" ;;
esac
say "Done. 'locket update' updates the command line; the app updates itself."

#!/usr/bin/env bash
# Build Locket from this checkout (the app's AppImage and the command line)
# and install it for this user, replacing the running copy:
#   ~/.local/bin/locket-app                         the desktop app (AppImage)
#   ~/.local/bin/locket                             the command line
#   ~/.local/share/applications/com.foreachdeveloper.locket.desktop
#   ~/.local/share/icons/hicolor/*/apps/com.foreachdeveloper.locket.png
#
#   scripts/install-local.sh              build and install, restart the app
#   NO_RESTART=1 scripts/install-local.sh leave the app stopped
#   NO_APP=1                              only the command line (no GTK needed)
#   NO_DESKTOP=1                          skip the launcher entry and icons
#   ORIEL_FORK=~/Code/oriel               build against a local Oriel checkout
#
# The vault ($XDG_DATA_HOME/locket, default ~/.local/share/locket) is never
# touched. Needs Zig 0.16 and, for the app, what Oriel's Linux build needs
# (GTK 4).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

fork=()
[ -n "${ORIEL_FORK:-}" ] && fork=(--fork="$(realpath "$ORIEL_FORK")")

version=$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon | head -n1)
appimage="zig-out/package/locket-app-$version-x86_64.AppImage"

echo "Building the locket $version command line"
zig build -Doptimize=ReleaseSafe "${fork[@]}"

if [ -z "${NO_APP:-}" ]; then
  rm -f "$appimage"
  echo "Building the Locket $version app (AppImage)"
  zig build package-appimage -Doptimize=ReleaseSafe "${fork[@]}"
  [ -f "$appimage" ] || { echo "error: $appimage was not produced" >&2; exit 1; }

  # Stop the running copy (the AppImage runtime and the app inside it).
  if pgrep -x locket-app >/dev/null; then
    echo "Stopping the running Locket"
    pkill -x locket-app || true
    for _ in $(seq 50); do pgrep -x locket-app >/dev/null || break; sleep 0.1; done
    pkill -9 -x locket-app 2>/dev/null || true
  fi
fi

mkdir -p ~/.local/bin
install -m755 zig-out/bin/locket ~/.local/bin/locket
echo "Installed the command line to ~/.local/bin/locket"
if [ -z "${NO_APP:-}" ]; then
  install -m755 "$appimage" ~/.local/bin/locket-app
  echo "Installed the app ($(du -h ~/.local/bin/locket-app | cut -f1)) to ~/.local/bin/locket-app"
fi

# The launcher entry and icons the packages ship, from the AppImage just built.
if [ -z "${NO_APP:-}" ] && [ -z "${NO_DESKTOP:-}" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  (cd "$tmp" && "$here/$appimage" --appimage-extract 'usr/share/*' >/dev/null)
  share="$tmp/squashfs-root/usr/share"
  apps=~/.local/share/applications
  mkdir -p "$apps"
  # Exec the installed AppImage, whether ~/.local/bin is on PATH or not.
  sed "s|^Exec=.*|Exec=$HOME/.local/bin/locket-app|" "$share/applications/com.foreachdeveloper.locket.desktop" > "$apps/com.foreachdeveloper.locket.desktop"
  for icon in "$share"/icons/hicolor/*/apps/com.foreachdeveloper.locket.png; do
    size=$(basename "$(dirname "$(dirname "$icon")")")
    install -Dm644 "$icon" ~/.local/share/icons/hicolor/"$size"/apps/com.foreachdeveloper.locket.png
  done
  command -v update-desktop-database >/dev/null && update-desktop-database "$apps" 2>/dev/null || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q ~/.local/share/icons/hicolor 2>/dev/null || true
  echo "Installed the launcher entry (Locket) and icons"
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "note: ~/.local/bin is not on PATH; add it to run 'locket' by name" ;;
esac

if [ -z "${NO_APP:-}" ] && [ -z "${NO_RESTART:-}" ]; then
  log="${XDG_STATE_HOME:-$HOME/.local/state}/locket/locket-app.log"
  mkdir -p "$(dirname "$log")"
  # Detach from the invoking terminal before it exits.
  nohup setsid ~/.local/bin/locket-app "$@" >>"$log" 2>&1 </dev/null &
  launch_pid=$!
  sleep 2
  if ! kill -0 "$launch_pid" 2>/dev/null; then
    echo "error: Locket exited during startup (log: $log)" >&2
    tail -n 20 "$log" >&2
    exit 1
  fi
  echo "Started Locket (log: $log)"
fi

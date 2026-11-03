# Changelog

All notable changes to Locket. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- **The app for arm64 Linux**: `locket-app-<version>-aarch64.AppImage`
  (updates itself, in `latest.json` as `aarch64-linux`) and its `.deb` and
  `.rpm`, built natively on GitHub's arm64 runner.
- **Install scripts** that install a release for your user, checked
  against `SHA256SUMS`: `scripts/install.sh` for Linux and macOS
  (`curl -fsSL …/install.sh | sh`) and `scripts/install.ps1` for Windows
  (`irm …/install.ps1 | iex`).

- **Sharing between machines.** `locket sync setup|join|now|status|stop|backends`,
  and a **Settings** page in the desktop app (sync, updates, about). Each
  machine keeps its full vault. Syncs merge every machine's edits, with
  the newest edit winning per variable, workspace and project, and deletions
  travel too. Commands sync before and after; the window syncs every
  30 seconds and after each edit.
- **Sync backends** behind one interface (`src/sync/connector.zig`,
  listed in `src/sync/connectors.zig`):
  - `nomadfs` reaches NomadFS's swarm folder through the running node's
    local API, with no mount; conditional writes on content ids.
  - `folder` uses any synced folder (Syncthing, Dropbox, a share, NomadFS's mount).
- **Shared key**: `key.json` wraps the vault key with a passphrase
  (Argon2id, 64 MiB, 3 passes; its parameters are bound into the seal).
- Vault format 3: every entry is stamped with the time and the machine of
  its last edit, and deletions leave tombstones. Formats 1 and 2 are read
  and upgraded.
- `config.json`: this machine's id and its sync backend.
- `locket run --expand`: `$NAME` and `${NAME}` in the command's
  arguments become the injected variables' values, for programs that take
  a secret as an argument (`... --expand -- kubectl exec -it pod -- mongo
  '$MONGO_URL'`).
- **Updates move the app and the command line together**: the app's
  update also updates the `locket` next to it, and `locket update` the
  `locket-app` next to it. A vault from a newer Locket now says so
  ("written by a newer Locket: update Locket") instead of "can't be
  decrypted".
- **Copy name** on every variable in the desktop app.
- **Shell completion**: `locket completion bash|zsh|fish` completes the
  commands, projects, workspaces and variable names. After `locket run
  <workspace> --`, it completes the command being run with that command's
  own completion.

### Changed

- Rekeying, used when joining, is crash-safe: `master.key.next` is
  written first, and an interrupted rekey is finished or dropped on the
  next open.

### Security

- `locket run` and `locket set` refuse variables that change how
  programs start (`LD_*`, `DYLD_*`, `BASH_ENV`, `NODE_OPTIONS`...), even
  when they come from a synced vault.
- Everything read from a backend is validated and bounded: names, stamps,
  8 MiB per file, 16 conflict copies per sync. The folder backend never
  follows links.
- The sync engine zeroes the memory it decrypts into; passphrases are
  typed without echo (Windows too) and wiped after use.

## 0.1.0 - 2026-11-03

The first release: a local secrets vault for AI agents, with a command
line (`locket`) and a desktop app (`locket-app`) on one shared core.

### Added

- **Vault** (`src/vault.zig`): one AES-256-GCM–sealed file
  (`vault.enc`) in `$XDG_DATA_HOME/locket`, keyed by a random 32-byte
  `master.key` (mode 0600).
- **Projects → workspaces → variables.** Every project has a `default`
  workspace, always first, that can't be renamed or removed; leaving the
  workspace out of an address means it.
- **Addresses**: `hub`, `hub/stage`, `hub/NAME` (in `hub/default`) and
  `hub/stage/NAME`, resolved in the core (`vault.Ref`) for both front ends.
- **`locket` CLI**:
  - `ls [project | project/workspace]`
  - `set project[/workspace]/NAME`, reading the value from stdin (never
    argv or shell history), and `get`
  - `rm` for one variable; `rm --workspace` and `rm --project` for the
    rest, so nothing larger goes by accident
  - `run project[/workspace] [--only A,B] [--prefix] -- command`: injects
    the workspace's variables into the command's environment under their
    stored names (`--prefix` for `LOCKET_<NAME>`) and returns its exit
    code (128+n for a signal). Locket prints only the workspace and a
    count, on stderr.
- **`locket-app` desktop app** (Oriel renderer: compiled `.oriel` views,
  no web view, no JavaScript), in the forEach developer design:
  - projects: create, select, rename and describe, delete
  - workspace tabs: create, select, rename, delete
  - variables: add, edit (rename and/or replace the value), show/hide
    (masked as `•••••••• N chars` by default), delete
  - delete confirmations, Enter to save, Esc to cancel, and the
    `locket run` line for the selected workspace
- **Safety**:
  - one writer at a time: edits hold an exclusive lock on `<data>/lock`
    from read to save; reads take a shared lock while reading
  - crash-safe saves: temp file, fsync, rename, directory fsync
  - a group- or world-readable `master.key` is refused
  - values and the key are zeroed when the vault is closed and when the
    window clears a field
- Name rules: 1–128 bytes, no spaces, `/` or control characters; no `=`
  in variable names.
- **Updates**: `locket update [--check] [--yes]` and the app's update
  button install the latest release after checking its Ed25519-signed
  manifest and the file's SHA-256 (Oriel's updater). `locket --version`
  and the app show the version, which lives only in `build.zig.zon`.
- **Linux, macOS and Windows**: the vault lives in
  `~/.local/share/locket`, `~/Library/Application Support/locket` or
  `%APPDATA%\locket` (`$LOCKET_HOME` overrides it). Releases ship the
  AppImage, deb and rpm, the macOS `.dmg`, the Windows `setup.exe`, and
  the CLI for x86_64/aarch64 Linux, macOS and x86_64 Windows; the deb and
  rpm include the CLI as `/usr/bin/locket`.
- **Release CI** (`.github/workflows/release.yml`): a `v*` tag tests and
  builds every platform, signs `latest.json` and `latest-cli.json`, and
  publishes the release. `scripts/release.sh X.Y.Z` bumps, tests and
  tags; `scripts/smoke.sh` checks a built CLI.
- The site, [locket.foreachdeveloper.com](https://locket.foreachdeveloper.com),
  built with Zine and deployed to Cloudflare Pages.
- `scripts/install-local.sh`: builds both programs and installs them for
  the user (`~/.local/bin/locket`, `~/.local/bin/locket-app` as an
  AppImage, the launcher entry and icons), replacing a running app.
- The app id `com.foreachdeveloper.locket` and Locket's icon: an amber
  locket with a teal keyhole (source: `docs/icon.svg`).
- `zig build test` (vault, CLI and input decoding, including an on-disk
  open/save/lock test) and `zig build atlas` (the zigatlas code map with
  the `app` → `front` → `core` layers).

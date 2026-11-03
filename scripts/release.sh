#!/usr/bin/env bash
# Cut a Locket release: set the version, commit, tag. Pushing the tag
# starts .github/workflows/release.yml, which builds Linux, macOS and
# Windows, signs the update manifests and publishes the GitHub release.
#
#   scripts/release.sh 0.2.0          bump, test, commit and tag v0.2.0
#   scripts/release.sh 0.2.0 --push   ...and push main and the tag
#
# Write the CHANGELOG.md entry first ("## 0.2.0 - YYYY-MM-DD"): the script
# and the release workflow both refuse a version without one. The version
# lives in one place, build.zig.zon; `locket --version`, the window, the
# packages and the update manifests all read it from there.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

v="${1:-}"
push="${2:-}"
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "usage: scripts/release.sh X.Y.Z [--push]" >&2; exit 2; }
[ -z "$push" ] || [ "$push" = --push ] || { echo "usage: scripts/release.sh X.Y.Z [--push]" >&2; exit 2; }

[ "$(git branch --show-current)" = main ] || { echo "error: release from main" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "error: commit or stash your changes first" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$v" >/dev/null && { echo "error: v$v is already tagged" >&2; exit 1; }
grep -q "^## $v\b" CHANGELOG.md || { echo "error: CHANGELOG.md has no '## $v' entry" >&2; exit 1; }

current=$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon | head -n1)
if [ "$current" != "$v" ]; then
  sed -i.bak "s/^\(\s*\.version = \"\)$current\",/\1$v\",/" build.zig.zon && rm -f build.zig.zon.bak
  echo "build.zig.zon: $current -> $v"
fi

echo "Running the tests"
zig build test
zig build -Dapp=false
./zig-out/bin/locket --version

git add build.zig.zon
git diff --cached --quiet || git commit -q -m "Release $v"
git tag -a "v$v" -m "Locket $v"
echo "Tagged v$v"

if [ "$push" = --push ]; then
  git push origin main "v$v"
  echo "Pushed: https://github.com/highercomve/locket/actions/workflows/release.yml"
else
  echo "Push it to build and publish the release:  git push origin main v$v"
fi

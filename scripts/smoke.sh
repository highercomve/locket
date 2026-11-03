#!/usr/bin/env bash
# Smoke-tests a built `locket` binary against a throwaway vault: version,
# set/get, the default and a named workspace, run's injection and exit
# code, and rm's guard. Used by CI on Linux, macOS and Windows (Git Bash).
#
#   scripts/smoke.sh zig-out/bin/locket
set -euo pipefail
bin="$1"
LOCKET_HOME="$(mktemp -d)"
export LOCKET_HOME
trap 'rm -rf "$LOCKET_HOME"' EXIT

fail() { echo "smoke: $*" >&2; exit 1; }

"$bin" --version | grep -q '^locket ' || fail "--version"
printf 'v-default' | "$bin" set hub/API_URL >/dev/null
printf 'v-stage' | "$bin" set hub/stage/TOKEN >/dev/null
[ "$("$bin" get hub/API_URL)" = v-default ] || fail "get from default"
[ "$("$bin" get hub/stage/TOKEN)" = v-stage ] || fail "get from stage"
[ "$("$bin" ls hub/stage)" = hub/stage/TOKEN ] || fail "ls"

# run: the child sees the stored name, Locket's own line goes to stderr.
out=$("$bin" run hub/stage -- printenv TOKEN 2>/dev/null)
[ "$out" = v-stage ] || fail "run injects (got '$out')"
out=$("$bin" run hub --prefix -- printenv LOCKET_API_URL 2>/dev/null)
[ "$out" = v-default ] || fail "run --prefix"
set +e
"$bin" run hub -- sh -c 'exit 7' 2>/dev/null
code=$?
set -e
[ "$code" = 7 ] || fail "run's exit code (got $code)"

# rm never removes a workspace by accident.
if "$bin" rm hub/stage 2>/dev/null; then fail "rm hub/stage removed a workspace"; fi
"$bin" rm --workspace hub/stage >/dev/null
"$bin" ls hub | grep -q 'hub/stage' && fail "rm --workspace"

echo "smoke: ok ($("$bin" --version))"

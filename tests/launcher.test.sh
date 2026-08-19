#!/usr/bin/env bash
# Asserts that bin/omarchy-rdp-launch and Model.js build the *same* FreeRDP
# argument list, and that the launcher refuses input it should refuse.
#
# This exists because they diverged for real: the launcher read its booleans with
# jq's `//`, which substitutes for false as well as null, so switching clipboard
# or dynamic-resolution off was silently ignored. node cannot catch that — only
# running both and diffing can.
#
# Run with: tests/launcher.test.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export OMARCHY_RDP_CONFIG_DIR="$TMP"

pass=0
fail=0
ok()   { pass=$((pass+1)); }
bad()  {
  fail=$((fail+1))
  printf 'FAIL: %s\n' "$1" >&2
  shift
  if [[ $# -gt 0 ]]; then printf '%s\n' "$@" >&2; fi
}
# refute <description> <command...> -- passes when the command FAILS, which is
# what every input-validation case here is asserting.
refute() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then bad "$desc"; else ok; fi
}

cat > "$TMP/connections.json" <<'JSON'
{
  "version": 1,
  "connections": [
    { "id": "baseline", "name": "Baseline", "host": "10.0.0.5", "port": 3389,
      "user": "Administrator", "domain": "",
      "drives": [ { "name": "home", "path": "/home/you/temp/demo" } ],
      "options": { "dynamicResolution": true, "clipboard": true, "cert": "tofu" } },
    { "id": "negatives", "name": "Negatives", "host": "rdp.example.com", "port": 4489,
      "user": "svc", "domain": "CORP",
      "drives": [],
      "options": { "dynamicResolution": false, "clipboard": false, "cert": "ignore" } },
    { "id": "multidrive", "name": "Many drives", "host": "10.0.0.6", "port": 3389,
      "user": "u", "domain": "",
      "drives": [ { "name": "one", "path": "/a" }, { "name": "two", "path": "/b" },
                  { "name": "three", "path": "/c" } ],
      "options": { "dynamicResolution": true, "clipboard": true, "cert": "deny" } },
    { "id": "noname", "name": "", "host": "10.0.0.7", "port": 3389,
      "user": "u", "domain": "",
      "drives": [], "options": {} }
  ]
}
JSON

model_args() {
  node -e '
    var M = require(process.env.ROOT + "/Model.js"), fs = require("fs")
    var cfg = M.parseConfig(fs.readFileSync(process.env.OMARCHY_RDP_CONFIG_DIR + "/connections.json", "utf8"))
    var c = M.findConnection(cfg.connections, process.argv[1])
    if (!c) { console.error("no such connection"); process.exit(1) }
    console.log(M.previewArgs(c).join("\n"))
  ' "$1"
}

launcher_args() {
  # Drop the trailing blank line and the human-readable comment footer.
  bin/omarchy-rdp-launch "$1" --dry-run | sed '/^$/,$d'
}

export ROOT

for id in baseline negatives multidrive noname; do
  a=$(launcher_args "$id")
  b=$(model_args "$id")
  if [[ "$a" == "$b" ]]; then
    ok
  else
    bad "launcher and Model.js disagree for '$id'" "$(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b"))"
  fi
done

# The regression that motivated this file.
args=$(launcher_args negatives)
if grep -qx -- '-clipboard' <<<"$args"; then ok; else bad "clipboard:false must emit -clipboard" "$args"; fi
if grep -qx -- '+clipboard' <<<"$args"; then bad "clipboard:false must not emit +clipboard" "$args"; else ok; fi
if grep -qx -- '+dynamic-resolution' <<<"$args"; then bad "dynamicResolution:false must not emit it" "$args"; else ok; fi

# The invariant the whole password design rests on.
count=$(grep -c '^/p:' <<<"$args")
if [[ "$count" == "1" ]]; then ok; else bad "expected exactly one /p: line, got $count"; fi
if grep -qx -- '/p:<redacted>' <<<"$args"; then ok; else bad "the dry run must redact the password"; fi

# wm-class drives status detection; a missing one silently breaks the icon.
for id in baseline negatives multidrive noname; do
  if grep -qx -- "/wm-class:omarchy-rdp-$id" <<<"$(launcher_args "$id")"; then
    ok
  else
    bad "missing /wm-class for '$id'"
  fi
done

# Port, domain and drive fan-out.
if grep -qx -- '/v:10.0.0.5' <<<"$(launcher_args baseline)"; then ok; else bad "default port must be omitted"; fi
if grep -qx -- '/v:rdp.example.com:4489' <<<"$(launcher_args negatives)"; then ok; else bad "custom port must be included"; fi
if grep -qx -- '/d:CORP' <<<"$(launcher_args negatives)"; then ok; else bad "domain must be passed"; fi
if grep -q '^/d:' <<<"$(launcher_args baseline)"; then bad "empty domain must not emit /d:"; else ok; fi
if [[ $(grep -c '^/drive:' <<<"$(launcher_args multidrive)") == "3" ]]; then ok; else bad "expected 3 /drive: lines"; fi

# Input the launcher must refuse.
refute "accepted a shell-metacharacter id" bin/omarchy-rdp-launch 'x; rm -rf /' --dry-run
refute "accepted a path-traversal id"       bin/omarchy-rdp-launch '../escape' --dry-run
refute "accepted an unknown id"             bin/omarchy-rdp-launch nosuchconnection --dry-run
refute "accepted a missing id"              bin/omarchy-rdp-launch --dry-run

# The focus helper must refuse the same shapes, and must not claim success for a
# session that has no window.
refute "focus helper accepted an invalid id"      bin/omarchy-rdp-focus 'Bad Id'
refute "focus helper accepted a missing id"       bin/omarchy-rdp-focus
refute "focus helper focused a nonexistent window" bin/omarchy-rdp-focus definitely-not-running

# The secret helper must refuse the same shapes.
refute "secret helper accepted an invalid id"     bin/omarchy-rdp-secret lookup 'Bad Id'
refute "secret helper accepted an unknown action" bin/omarchy-rdp-secret bogus-action someid

# The status helper must survive an empty and a corrupt state directory.
export OMARCHY_RDP_STATE_DIR="$TMP/state"
out=$(bin/omarchy-rdp-status)
if [[ "$(jq -r '.sessions | length' <<<"$out")" == "0" ]]; then ok; else bad "missing state dir should yield no sessions: $out"; fi
mkdir -p "$OMARCHY_RDP_STATE_DIR" && chmod 700 "$OMARCHY_RDP_STATE_DIR"
echo 'not json' > "$OMARCHY_RDP_STATE_DIR/broken.state"
out=$(bin/omarchy-rdp-status)
if jq -e . >/dev/null 2>&1 <<<"$out"; then ok; else bad "a corrupt state file broke the status output: $out"; fi
if [[ "$(jq -r '.sessions | length' <<<"$out")" == "0" ]]; then ok; else bad "corrupt state should be skipped: $out"; fi

# --- state directory must be ours and private ------------------------------
#
# omarchy-rdp-disconnect reads a pid from a state file and SIGTERMs it, so a
# state directory that is world-writable, group-writable, or a symlink lets
# someone else choose the target. Each case below fails against the original
# code, which took ${XDG_RUNTIME_DIR:-/tmp}/omarchy-rdp on trust.

hostile="$TMP/hostile"
mkdir -p "$hostile"
chmod 777 "$hostile"
out=$(OMARCHY_RDP_STATE_DIR="$hostile" bin/omarchy-rdp-status 2>/dev/null)
if [[ "$(jq -r '.error' <<<"$out")" == *"mode 700"* ]]; then ok; else bad "status trusted a world-writable state dir: $out"; fi
if [[ "$(jq -r '.sessions | length' <<<"$out")" == "0" ]]; then ok; else bad "status read sessions from a world-writable dir"; fi

# A planted state file must not be turned into a signal. The pid used is a real
# process this test owns and can watch, so the assertion is that the victim is
# still alive afterwards — not merely that the command exited non-zero, which it
# would do anyway for a pid we cannot signal.
plant_and_check() {
  local dir=$1 desc=$2 victim
  sleep 300 &
  victim=$!
  jq -n --argjson pid "$victim" \
    '{id:"planted",pid:$pid,phase:"connected",wmClass:"omarchy-rdp-planted",host:"h",startedAt:0,exitCode:null,message:""}' \
    > "$dir/planted.state" 2>/dev/null
  OMARCHY_RDP_STATE_DIR="$dir" bin/omarchy-rdp-disconnect planted >/dev/null 2>&1
  sleep 0.3
  if kill -0 "$victim" 2>/dev/null; then ok; else bad "$desc"; fi
  kill "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
}

plant_and_check "$hostile" "disconnect signalled a pid from a world-writable state dir"

groupwritable="$TMP/groupwritable"
mkdir -p "$groupwritable"
chmod 770 "$groupwritable"
plant_and_check "$groupwritable" "disconnect signalled a pid from a group-writable state dir"

private="$TMP/private"
mkdir -p "$private"
chmod 700 "$private"
linked="$TMP/linked"
ln -sfn "$private" "$linked"
plant_and_check "$linked" "disconnect followed a symlinked state dir and signalled a pid"

# The good case still works: a private directory of our own is accepted.
out=$(OMARCHY_RDP_STATE_DIR="$private" bin/omarchy-rdp-status 2>/dev/null)
if [[ "$(jq -r '.error' <<<"$out")" == "" ]]; then ok; else bad "a private state dir was rejected: $out"; fi

printf 'launcher.test.sh: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]

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
# "auto" resolves against the focused monitor, so without pinning it the two
# sides would ask a compositor that does not exist on a CI runner, and locally
# the comparison would drift with whatever screen the developer is on.
export OMARCHY_RDP_AUTO_SIZE=5120x1440

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

# expect_exit <code> <description> <command...>
expect_exit() {
  local want=$1 desc=$2
  shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [[ "$got" == "$want" ]]; then ok; else bad "$desc (expected exit $want, got $got)"; fi
}

# Every helper must exist before the cases run. Without `set -e` a helper that is
# defined further down the file is just "command not found" on stderr: the
# assertions using it never run, and the suite still reports a clean pass. That
# happened while adding the #3 cases, so it is checked rather than assumed.
for helper in ok bad refute expect_exit; do
  if ! declare -F "$helper" >/dev/null; then
    printf 'FATAL: helper %s is not defined before the test cases\n' "$helper" >&2
    exit 1
  fi
done

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
      "drives": [], "options": {} },
    { "id": "fixed-auto", "name": "Fixed auto", "host": "10.0.0.8", "port": 3389,
      "user": "u", "domain": "",
      "drives": [], "options": { "displayMode": "fixed", "resolution": "auto" } },
    { "id": "scaled-explicit", "name": "Scaled explicit", "host": "10.0.0.9", "port": 3389,
      "user": "u", "domain": "",
      "drives": [], "options": { "displayMode": "scaled", "resolution": "1920x1080" } },
    { "id": "dynamic-explicit", "name": "Dynamic explicit", "host": "10.0.0.10", "port": 3389,
      "user": "u", "domain": "",
      "drives": [], "options": { "displayMode": "dynamic", "resolution": "1280x1024" } },
    { "id": "bad-resolution", "name": "Bad resolution", "host": "10.0.0.11", "port": 3389,
      "user": "u", "domain": "",
      "drives": [], "options": { "displayMode": "fixed", "resolution": "99x99" } },
    { "id": "unicode-resolution", "name": "Unicode resolution", "host": "10.0.0.12", "port": 3389,
      "user": "u", "domain": "",
      "drives": [], "options": { "displayMode": "fixed", "resolution": "1600 \u00d7 900" } }
  ]
}
JSON

model_args() {
  node -e '
    var M = require(process.env.ROOT + "/Model.js"), fs = require("fs")
    var cfg = M.parseConfig(fs.readFileSync(process.env.OMARCHY_RDP_CONFIG_DIR + "/connections.json", "utf8"))
    var c = M.findConnection(cfg.connections, process.argv[1])
    if (!c) { console.error("no such connection"); process.exit(1) }
    var parts = String(process.env.OMARCHY_RDP_AUTO_SIZE || "").split("x")
    console.log(M.previewArgs(c, { width: Number(parts[0]), height: Number(parts[1]) }).join("\n"))
  ' "$1"
}

launcher_args() {
  # Drop the trailing blank line and the human-readable comment footer.
  bin/omarchy-rdp-launch "$1" --dry-run | sed '/^$/,$d'
}

export ROOT

for id in baseline negatives multidrive noname fixed-auto scaled-explicit dynamic-explicit bad-resolution unicode-resolution; do
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
for id in baseline negatives multidrive noname fixed-auto scaled-explicit dynamic-explicit bad-resolution unicode-resolution; do
  if grep -qx -- "/wm-class:omarchy-rdp-$id" <<<"$(launcher_args "$id")"; then
    ok
  else
    bad "missing /wm-class for '$id'"
  fi
done

# Sizing. FreeRDP exits 22 when /smart-sizing and +dynamic-resolution are both
# present, so "exactly one of them" is an invariant, not a style preference.
for id in baseline negatives multidrive noname fixed-auto scaled-explicit dynamic-explicit bad-resolution unicode-resolution; do
  a=$(launcher_args "$id")
  n=$(grep -c '^/size:' <<<"$a")
  if [[ "$n" == "1" ]]; then ok; else bad "'$id' must emit exactly one /size:, got $n" "$a"; fi
  smart=$(grep -cx -- '/smart-sizing' <<<"$a")
  dyn=$(grep -cx -- '+dynamic-resolution' <<<"$a")
  if (( smart + dyn <= 1 )); then ok; else bad "'$id' emits both /smart-sizing and +dynamic-resolution (FreeRDP exits 22)" "$a"; fi
done

if grep -qx -- '/size:1920x1080' <<<"$(launcher_args scaled-explicit)"; then ok; else bad "explicit resolution must be used verbatim"; fi
if grep -qx -- '/smart-sizing' <<<"$(launcher_args scaled-explicit)"; then ok; else bad "scaled mode must emit /smart-sizing"; fi
if grep -qx -- '+dynamic-resolution' <<<"$(launcher_args scaled-explicit)"; then bad "scaled mode must not emit +dynamic-resolution"; else ok; fi
if grep -qx -- '+dynamic-resolution' <<<"$(launcher_args dynamic-explicit)"; then ok; else bad "dynamic mode must emit +dynamic-resolution"; fi
# Under dynamic the size is only where the window opens, but it is still
# honoured: without it FreeRDP would start every session at 1024x768. The
# fixture asks for 1280x1024 so a silently-dropped value would be visible.
if grep -qx -- '/size:1280x1024' <<<"$(launcher_args dynamic-explicit)"; then ok; else bad "dynamic mode must honour the starting size" "$(launcher_args dynamic-explicit)"; fi
if grep -qx -- '/smart-sizing' <<<"$(launcher_args fixed-auto)"; then bad "fixed mode must not emit /smart-sizing"; else ok; fi
if grep -qx -- '+dynamic-resolution' <<<"$(launcher_args fixed-auto)"; then bad "fixed mode must not emit +dynamic-resolution"; else ok; fi
# 5120x1440 clamps to the 2560x1440 cap rather than being asked for verbatim.
if grep -qx -- '/size:2560x1440' <<<"$(launcher_args fixed-auto)"; then ok; else bad "auto must clamp the monitor size to the cap"; fi
# An unusable value falls back to auto instead of reaching FreeRDP.
if grep -qx -- '/size:2560x1440' <<<"$(launcher_args bad-resolution)"; then ok; else bad "an out-of-range resolution must fall back to auto"; fi
# The legacy boolean still selects the mode it used to mean.
if grep -qx -- '+dynamic-resolution' <<<"$(launcher_args baseline)"; then ok; else bad "legacy dynamicResolution:true must still mean dynamic"; fi

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

# --- a recycled pid must not be signalled ----------------------------------
#
# Regression for #3: disconnect checked the state file's pid with `kill -0` and
# nothing else. That proves only that *a* process holds the pid, so a state file
# left by a launcher that died without writing a terminal state, plus a recycled
# pid, made Disconnect SIGTERM an unrelated process of the user's. The status
# helper had the mirror problem: `kill -0` succeeding meant the phantom session
# was never reaped and sat in the panel forever.

stale="$TMP/stale"
mkdir -p "$stale"
chmod 700 "$stale"

# Each case gets a fresh bystander. Sharing one let the first case kill it, after
# which every later case passed vacuously against the buggy code.
disconnect_must_not_signal() {
  local ticks_mode=$1 desc=$2 victim ticks
  sleep 300 &
  victim=$!
  sleep 0.2
  case $ticks_mode in
    # A start time that does not belong to this pid: what a recycled pid looks like.
    mismatch) ticks="1" ;;
    # A state file written before this check existed cannot be verified.
    missing)  ticks="" ;;
  esac
  jq -n --argjson pid "$victim" --arg ticks "$ticks" \
    '{id:"stalesession",pid:$pid,startTicks:$ticks,phase:"connected",
      wmClass:"omarchy-rdp-stalesession",host:"10.0.0.5",startedAt:0,
      exitCode:null,message:""}' > "$stale/stalesession.state"

  OMARCHY_RDP_STATE_DIR="$stale" bin/omarchy-rdp-disconnect stalesession >/dev/null 2>&1
  local code=$?
  sleep 0.3
  if kill -0 "$victim" 2>/dev/null; then ok; else bad "$desc"; fi
  if [[ $code -ne 0 ]]; then ok; else bad "$desc (disconnect reported success)"; fi

  # Status must reap it, not report a live session forever.
  local phase
  phase=$(OMARCHY_RDP_STATE_DIR="$stale" bin/omarchy-rdp-status 2>/dev/null \
    | jq -r '.sessions[] | select(.id=="stalesession") | .phase')
  if [[ "$phase" == "stopped" ]]; then ok; else bad "$desc (status reported '$phase')"; fi

  kill "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
}

disconnect_must_not_signal mismatch "an unrelated process was signalled via a recycled pid"
disconnect_must_not_signal missing  "an unrelated process was signalled via an unverifiable state file"

# The status helper's half of #3, tested without disconnect touching anything:
# with the pid alive but its start time not matching, the old code kept reporting
# a live session forever, because `kill -0` succeeded and the window check merely
# downgraded it to "connecting".
sleep 300 &
phantom=$!
sleep 0.2
jq -n --argjson pid "$phantom" \
  '{id:"phantom",pid:$pid,startTicks:"1",phase:"connected",
    wmClass:"omarchy-rdp-phantom",host:"10.0.0.5",startedAt:0,
    exitCode:null,message:""}' > "$stale/phantom.state"
phantom_phase=$(OMARCHY_RDP_STATE_DIR="$stale" bin/omarchy-rdp-status 2>/dev/null \
  | jq -r '.sessions[] | select(.id=="phantom") | .phase')
if [[ "$phantom_phase" == "stopped" ]]; then ok; else bad "status reported a recycled pid as '$phantom_phase' instead of reaping it"; fi
kill "$phantom" 2>/dev/null
wait "$phantom" 2>/dev/null
rm -f "$stale/phantom.state"

# The honest case must still work: the real pid with its real start time.
sleep 300 &
genuine=$!
sleep 0.2
genuine_ticks=$(awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$genuine/stat")
jq -n --argjson pid "$genuine" --arg ticks "$genuine_ticks" \
  '{id:"stalesession",pid:$pid,startTicks:$ticks,phase:"connected",
    wmClass:"omarchy-rdp-stalesession",host:"10.0.0.5",startedAt:0,
    exitCode:null,message:""}' > "$stale/stalesession.state"
OMARCHY_RDP_STATE_DIR="$stale" bin/omarchy-rdp-disconnect stalesession >/dev/null 2>&1
sleep 0.4
if kill -0 "$genuine" 2>/dev/null; then bad "a verified pid was not signalled"; else ok; fi
kill "$genuine" 2>/dev/null
wait "$genuine" 2>/dev/null

# --- the secret helper must never report success for a failed write ---------
#
# Regression for #1: `$?` was captured inside `if ! cmd; then`, which yields the
# status of the negation (always 0 when cmd failed) rather than of secret-tool.
# That 0 was passed to `die`, so the helper exited 0 and the panel marked the
# password as stored while the keyring held nothing or the previous credential.
#
# secret-tool's path is hardcoded on purpose — an env-overridable binary path in a
# credential helper is not worth the testability — so these cases build a fixture
# from the real script with the path and timeouts substituted.

secret_fixture() {
  local tool=$1 out="$TMP/secret-fixture"
  sed -e "s|^SECRET_TOOL=.*|SECRET_TOOL=$tool|" \
      -e "s|^STORE_TIMEOUT=.*|STORE_TIMEOUT=1|" \
      -e "s|^LOOKUP_TIMEOUT=.*|LOOKUP_TIMEOUT=1|" \
      bin/omarchy-rdp-secret > "$out"
  chmod +x "$out"
  printf '%s' "$out"
}

printf '#!/bin/sh\nexit 3\n' > "$TMP/failing-keyring"; chmod +x "$TMP/failing-keyring"
printf '#!/bin/sh\nsleep 30\n' > "$TMP/hanging-keyring"; chmod +x "$TMP/hanging-keyring"

failing=$(secret_fixture "$TMP/failing-keyring")
# A non-zero secret-tool must surface as non-zero, and specifically not as 0.
expect_exit 3 "store reported success for a failing keyring write" \
  env - PATH="$PATH" "$failing" store demo-conn
expect_exit 1 "lookup misreported a failing keyring read" \
  env - PATH="$PATH" "$failing" lookup demo-conn

hanging=$(secret_fixture "$TMP/hanging-keyring")
# A write killed by `timeout` must surface as 124 so the panel can say the keyring
# did not respond, rather than claiming the password was saved.
expect_exit 124 "store reported success for a timed-out keyring write" \
  env - PATH="$PATH" "$hanging" store demo-conn
# And a timed-out read must not masquerade as "no password stored".
expect_exit 124 "lookup reported a locked keyring as 'not stored'" \
  env - PATH="$PATH" "$hanging" lookup demo-conn

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

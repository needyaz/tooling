#!/usr/bin/env bash
# This repo's own tests. Offline: docker, supabase, xcodebuild and xcrun are stubs.
#   tests/run.sh
set -u

REPO="$(cd -P "$(dirname "$0")/.." && pwd -P)"
T="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [ -z "${2:-}" ] || echo "$2" | sed 's/^/       /'; }
check() { # check DESC STATUS(0=true) [DETAIL]
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

# --- stubs --------------------------------------------------------------------------------------------
STUBS="$T/stubs"; STATE="$T/state"; mkdir -p "$STUBS" "$STATE/running"
export STUB_STATE="$STATE" STUB_LOG="$STATE/calls.log"
: > "$STUB_LOG"

cat > "$STUBS/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
case "$1" in
  inspect)
    for a in "$@"; do last="$a"; done
    if [ -f "$STUB_STATE/running/$last" ]; then echo true; else echo false; exit 1; fi ;;
esac
exit 0
EOF
cat > "$STUBS/supabase" <<'EOF'
#!/usr/bin/env bash
echo "supabase $*" >> "$STUB_LOG"
id="$(sed -n 's/^project_id = "\(.*\)"/\1/p' build/local-supabase/supabase/config.toml 2>/dev/null | head -1)"
case "$1" in
  start) touch "$STUB_STATE/running/supabase_db_$id" ;;
  stop)  rm -f "$STUB_STATE/running/supabase_db_$id" ;;
  functions)
    # `functions serve`: a leader that forks a child, like the real CLI.
    touch "$STUB_STATE/running/supabase_edge_runtime_$id"
    sleep 300 > /dev/null 2>&1 &
    echo $! > "$STUB_STATE/fn-child"
    echo "Serving functions"
    wait ;;
esac
exit 0
EOF
cat > "$STUBS/xcodebuild" <<'EOF'
#!/usr/bin/env bash
echo "xcodebuild $*" >> "$STUB_LOG"
echo "NOISE compiling"
case "${XCB_MODE:-ok}" in
  ok)   echo "Test Suite 'All tests' started"; echo "Test Case '-[A t1]' passed"; exit 0 ;;
  fail) echo "Test Case '-[A t1]' failed"; echo "x.swift:1: error: boom"; exit 65 ;;
  zero) echo "Executed 0 tests, with 0 failures"; exit 0 ;;
esac
EOF
cat > "$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
printf 200
EOF
cat > "$STUBS/flutter" <<'EOF'
#!/usr/bin/env bash
echo "flutter $*" >> "$STUB_LOG"
[ -z "${FLUTTER_FAIL:-}" ] || exit 4
exit 0
EOF
cat > "$STUBS/xcrun" <<'EOF'
#!/usr/bin/env bash
echo "xcrun $*" >> "$STUB_LOG"
case "$2" in
  list) cat "$STUB_STATE/sims.json" ;;
esac
exit 0
EOF
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

# A fresh app dir with the toolkit vendored into it.
new_app() { # new_app NAME -> path
  local app="$T/$1"
  mkdir -p "$app/supabase"
  printf 'project_id = "orig"\n\n[api]\nport = 54321\n\n[db.migrations]\nenabled = true\n' > "$app/supabase/config.toml"
  "$REPO/bin/tooling-sync" "$app" >/dev/null
  echo "$app"
}
reset_stack() { rm -f "$STATE"/running/*; : > "$STUB_LOG"; }

export TOOLING_LOCK_DIR="$T/locks" TOOLING_LOCK_TIMEOUT=2 TOOLING_LOCK_INTERVAL=1
LOCK="$TOOLING_LOCK_DIR/supabase-stack.lock"
APP="$(new_app app)"
SL() { ( cd "$APP" && TOOLING_APP_ROOT="$APP" "$REPO/bin/supabase-local" "$@" ); }
holder() { # holder NAME RUNNING(yes|no) [mtime]
  rm -rf "$LOCK"; mkdir -p "$LOCK"
  echo "$1" > "$LOCK/owner"; echo "supabase_db_$1" > "$LOCK/container"
  if [ "$2" = yes ]; then touch "$STATE/running/supabase_db_$1"; else rm -f "$STATE/running/supabase_db_$1"; fi
  [ -z "${3:-}" ] || touch -t "$3" "$LOCK"
}

echo "supabase-local url"
out="$(SUPABASE_LOCAL_URL=http://example.com:54321 SL url 2>&1)"; st=$?
check "refuses a non-loopback URL" "$([ $st -ne 0 ] && echo 0 || echo 1)" "$out"
out="$(SUPABASE_LOCAL_URL=http://localhost:1@example.com SL url 2>&1)"; st=$?
check "refuses a loopback-looking URL with userinfo" "$([ $st -ne 0 ] && echo 0 || echo 1)" "$out"
out="$(SUPABASE_LOCAL_URL=http://127.0.0.1:54321 SL url 2>&1)"; st=$?
check "accepts 127.0.0.1" "$([ $st -eq 0 ] && [ "$out" = http://127.0.0.1:54321 ] && echo 0 || echo 1)" "$out"
out="$(SUPABASE_LOCAL_URL=http://localhost:54321 SL url 2>&1)"; st=$?
check "accepts localhost" "$([ $st -eq 0 ] && [ "$out" = http://localhost:54321 ] && echo 0 || echo 1)" "$out"

echo "supabase-local lock"
export SUPABASE_LOCAL_ID=mine
reset_stack; holder other yes
out="$(SL lock 2>&1)"; st=$?
check "held by a running stack: waits, then refuses naming the holder" \
  "$([ $st -ne 0 ] && echo "$out" | grep -q 'waiting' && echo "$out" | grep -q 'other' && echo 0 || echo 1)" "$out"
check "the holder keeps the lock" "$([ "$(cat "$LOCK/owner")" = other ] && echo 0 || echo 1)"

reset_stack; holder other no 200001010000
out="$(SL lock 2>&1)"; st=$?
check "stopped container and old lock: broken and taken" \
  "$([ $st -eq 0 ] && [ "$(cat "$LOCK/owner")" = mine ] && echo 0 || echo 1)" "$out"

reset_stack; holder other no
out="$(SL lock 2>&1)"; st=$?
check "stopped container but fresh lock: not broken" \
  "$([ $st -ne 0 ] && [ "$(cat "$LOCK/owner")" = other ] && echo 0 || echo 1)" "$out"

reset_stack; rm -rf "$LOCK"
SL lock >/dev/null 2>&1; a=$?; SL lock >/dev/null 2>&1; b=$?
check "taking it again as the owner is a no-op" \
  "$([ $a -eq 0 ] && [ $b -eq 0 ] && [ "$(cat "$LOCK/owner")" = mine ] && echo 0 || echo 1)"
SL unlock >/dev/null 2>&1
check "unlock releases our own lock" "$([ ! -e "$LOCK" ] && echo 0 || echo 1)"

reset_stack; holder other yes
SL unlock >/dev/null 2>&1
check "unlock never releases another stack's lock" \
  "$([ "$(cat "$LOCK/owner" 2>/dev/null)" = other ] && echo 0 || echo 1)"
rm -rf "$LOCK"

echo "supabase-local up / down"
reset_stack
python3 -I -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(120)
' "$T/port" &
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/port" ] && break; sleep 0.3; done
port="$(cat "$T/port")"
out="$(SUPABASE_LOCAL_URL="http://127.0.0.1:$port" SL up 2>&1)"; st=$?
check "up refuses when the API port is bound" "$([ $st -ne 0 ] && echo "$out" | grep -q 'already bound' && echo 0 || echo 1)" "$out"
check "up never reaches supabase start" "$(grep -q 'supabase start' "$STUB_LOG" && echo 1 || echo 0)"
check "up releases the lock it took" "$([ ! -e "$LOCK" ] && echo 0 || echo 1)"
kill $(jobs -p) 2>/dev/null; wait 2>/dev/null

reset_stack
out="$(SUPABASE_LOCAL_URL=http://127.0.0.1:1 SL up 2>&1)"; st=$?
cfg="$APP/build/local-supabase/supabase/config.toml"
check "up starts the stack with the generated config" \
  "$([ $st -eq 0 ] && grep -q 'supabase start' "$STUB_LOG" && grep -q '^project_id = "mine"' "$cfg" && grep -A1 '^\[db.migrations\]' "$cfg" | grep -q 'enabled = false' && echo 0 || echo 1)" "$out"
check "up leaves supabase/config.toml alone" "$(grep -q 'project_id = "orig"' "$APP/supabase/config.toml" && echo 0 || echo 1)"
check "up arms the guard (0600)" "$([ -s "$APP/build/local-supabase/guard" ] && [ "$(stat -c %a "$APP/build/local-supabase/guard" 2>/dev/null || stat -f %Lp "$APP/build/local-supabase/guard")" = 600 ] && echo 0 || echo 1)"
SL down >/dev/null 2>&1
check "down stops the stack, drops the guard and releases the lock" \
  "$(grep -q 'supabase stop' "$STUB_LOG" && [ ! -e "$APP/build/local-supabase/guard" ] && [ ! -e "$LOCK" ] && echo 0 || echo 1)"
unset SUPABASE_LOCAL_ID

echo "supabase-local db-url"
out="$(env -u SUPABASE_LOCAL_DB_PORT "$REPO/bin/supabase-local" db-url 2>&1)"
check "db-url defaults to port 54322, no stack needed" "$([ "$out" = postgresql://postgres:postgres@127.0.0.1:54322/postgres ] && echo 0 || echo 1)" "$out"
out="$(SUPABASE_LOCAL_DB_PORT=65535 SL db-url 2>&1)"
check "db-url takes SUPABASE_LOCAL_DB_PORT" "$([ "$out" = postgresql://postgres:postgres@127.0.0.1:65535/postgres ] && echo 0 || echo 1)" "$out"
for bad in abc 0 054322 65536 -1 5432.1 '' ' 5432' 1234567890123; do
  out="$(SUPABASE_LOCAL_DB_PORT="$bad" SL db-url 2>&1)"; st=$?
  check "db-url rejects SUPABASE_LOCAL_DB_PORT='$bad'" "$([ $st -eq 1 ] && echo "$out" | grep -q 'SUPABASE_LOCAL_DB_PORT' && echo 0 || echo 1)" "$out"
done

echo "supabase-local functions (process group)"
export SUPABASE_LOCAL_ID=fnapp TOOLING_STOP_WAIT=2
mkdir -p "$APP/supabase/functions/fn-version"; echo x > "$APP/supabase/functions/fn-version/index.ts"
reset_stack; rm -f "$STATE/fn-child"
SL up >/dev/null 2>&1
BW="$APP/build/local-supabase"
alive() { kill -0 "$1" 2>/dev/null; }
gone() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do alive "$1" || return 0; sleep 0.2; done; return 1; }
out="$(SL functions-up 2>&1)"; st=$?
child1="$(cat "$STATE/fn-child")"; leader1="$(cat "$BW/functions.pid")"
check "functions-up serves in its own group, recorded" \
  "$([ $st -eq 0 ] && [ "$(cat "$BW/functions.pgid")" = "$leader1" ] && [ "$(ps -o pgid= -p "$child1" | tr -d ' ')" = "$leader1" ] && echo 0 || echo 1)" "$out"
SL functions-down >/dev/null 2>&1
check "functions-down kills the whole group (the forked child too)" \
  "$(gone "$child1" && gone "$leader1" && [ ! -e "$BW/functions.pgid" ] && echo 0 || echo 1)"

SL functions-up >/dev/null 2>&1
child1="$(cat "$STATE/fn-child")"; leader1="$(cat "$BW/functions.pid")"
kill -9 "$leader1"; gone "$leader1"
check "after the leader dies the group is leaderless and still running" \
  "$(alive "$child1" && SL functions-status | grep -q leaderless && echo 0 || echo 1)"
out="$(SL functions-up 2>&1)"; st=$?
child2="$(cat "$STATE/fn-child")"; leader2="$(cat "$BW/functions.pid")"
check "functions-up stops a leaderless group and starts a fresh one" \
  "$([ $st -eq 0 ] && gone "$child1" && [ "$child2" != "$child1" ] && alive "$child2" && alive "$leader2" && [ "$leader2" != "$leader1" ] && echo 0 || echo 1)" "$out"
SL down >/dev/null 2>&1
check "down also stops the functions group" "$(gone "$child2" && echo 0 || echo 1)"
unset SUPABASE_LOCAL_ID TOOLING_STOP_WAIT

echo "supabase-local abs-workdir"
mkdir -p "$T/real/app/tooling" "$T/real/app/supabase"
cp -R "$APP/tooling/." "$T/real/app/tooling/"
ln -s "$T/real/app" "$T/link"
out="$("$T/link/tooling/bin/supabase-local" abs-workdir 2>&1)"
want="$(cd -P "$T/real/app" && pwd -P)/build/local-supabase"
check "abs-workdir is the physical path through a symlinked app" "$([ "$out" = "$want" ] && echo 0 || echo 1)" "got: $out
want: $want"

echo "logged"
mkdir -p "$T/lg"
out="$(cd "$T/lg" && "$REPO/bin/logged" demo -- sh -c 'echo out; echo err >&2; exit 3')"; st=$?
check "keeps the command's exit status" "$([ $st -eq 3 ] && echo 0 || echo 1)"
check "prints ✗, the name and the log path" "$(echo "$out" | grep -q '^✗ demo [0-9]*s build/logs/demo-.*\.log$' && echo 0 || echo 1)" "$out"
log1="$T/lg/$(echo "$out" | awk '{print $NF}')"
check "the log has stdout and stderr" "$(grep -q '^out$' "$log1" && grep -q '^err$' "$log1" && echo 0 || echo 1)"
cp "$log1" "$T/log1.copy"
out2="$(cd "$T/lg" && "$REPO/bin/logged" demo -- sh -c 'echo second')"; st=$?
check "a successful run prints ✓ and exits 0" "$([ $st -eq 0 ] && echo "$out2" | grep -q '^✓ demo' && echo 0 || echo 1)" "$out2"
check "one log file per run, the first untouched" \
  "$([ "$(ls "$T/lg/build/logs" | wc -l | tr -d ' ')" = 2 ] && cmp -s "$log1" "$T/log1.copy" && echo 0 || echo 1)"

echo "xcuitest"
mkdir -p "$T/xc"
export TOOLING_APP_ROOT="$T/xc"
out="$(cd "$T/xc" && XCB_MODE=fail "$REPO/bin/xcuitest" ui -- -scheme S 2>&1)"; st=$?
check "passes through a failing xcodebuild status" "$([ $st -eq 65 ] && echo 0 || echo 1)" "$out"
check "prints only Test Case/Suite/error lines" "$(echo "$out" | grep -q 'error: boom' && ! echo "$out" | grep -q NOISE && echo 0 || echo 1)" "$out"
check "the full log keeps everything" "$(grep -q NOISE "$T"/xc/build/logs/ui-*.log && echo 0 || echo 1)"
out="$(cd "$T/xc" && XCB_MODE=zero "$REPO/bin/xcuitest" ui -- -scheme S 2>&1)"; st=$?
check "fails a run that executed 0 tests" "$([ $st -ne 0 ] && echo "$out" | grep -q 'no tests executed' && echo 0 || echo 1)" "$out"
out="$(cd "$T/xc" && XCB_MODE=ok "$REPO/bin/xcuitest" ui -- -scheme S 2>&1)"; st=$?
check "passes a run with passing tests" "$([ $st -eq 0 ] && echo 0 || echo 1)" "$out"

mkdir -p "$T/xcf"; echo 'TOOLING_FOOTPRINTS=flutter' > "$T/xcf/tooling.env"
: > "$STUB_LOG"
out="$(cd "$T/xcf" && TOOLING_APP_ROOT="$T/xcf" "$REPO/bin/xcuitest" ui -- -scheme S 2>&1)"; st=$?
check "flutter footprint: regenerates the iOS config first (logged), then runs xcodebuild" \
  "$([ $st -eq 0 ] && [ "$(sed -n 1p "$STUB_LOG")" = 'flutter build ios --simulator --debug --config-only' ] && sed -n 2p "$STUB_LOG" | grep -q '^xcodebuild test' && ls "$T"/xcf/build/logs/ui-flutter-config-*.log >/dev/null 2>&1 && echo 0 || echo 1)" "$out
$(cat "$STUB_LOG")"
: > "$STUB_LOG"
out="$(cd "$T/xcf" && XCUITEST_SKIP_FLUTTER_CONFIG=1 TOOLING_APP_ROOT="$T/xcf" "$REPO/bin/xcuitest" ui -- -scheme S 2>&1)"; st=$?
check "XCUITEST_SKIP_FLUTTER_CONFIG=1 skips it" "$([ $st -eq 0 ] && ! grep -q '^flutter' "$STUB_LOG" && echo 0 || echo 1)" "$out"
: > "$STUB_LOG"
out="$(cd "$T/xcf" && FLUTTER_FAIL=1 TOOLING_APP_ROOT="$T/xcf" "$REPO/bin/xcuitest" ui -- -scheme S 2>&1)"; st=$?
check "a failing config step stops the run with its status" "$([ $st -eq 4 ] && ! grep -q '^xcodebuild' "$STUB_LOG" && echo 0 || echo 1)" "$out"
: > "$STUB_LOG"
out="$(cd "$T/xc" && "$REPO/bin/xcuitest" ui -- -scheme S 2>&1)"
check "no flutter footprint: no config step" "$(! grep -q '^flutter' "$STUB_LOG" && echo 0 || echo 1)"
unset TOOLING_APP_ROOT

echo "with-local-stack"
cat > "$T/fake-sl" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$WLS_LOG"
[ "$1" = up ] && [ -n "${WLS_UP_FAIL:-}" ] && exit 9
exit 0
EOF
chmod +x "$T/fake-sl"
export TOOLING_SUPABASE_LOCAL="$T/fake-sl" WLS_LOG="$T/wls.log"
: > "$WLS_LOG"
"$REPO/bin/with-local-stack" -- sh -c 'exit 7'; st=$?
check "returns the command's status" "$([ $st -eq 7 ] && echo 0 || echo 1)"
check "runs up, then down, even when the command fails" "$([ "$(tr '\n' ' ' < "$WLS_LOG")" = 'up down ' ] && echo 0 || echo 1)" "$(cat "$WLS_LOG")"
: > "$WLS_LOG"
"$REPO/bin/with-local-stack" --functions -- true; st=$?
check "--functions serves the functions and succeeds" "$([ $st -eq 0 ] && [ "$(tr '\n' ' ' < "$WLS_LOG")" = 'up functions-up down ' ] && echo 0 || echo 1)" "$(cat "$WLS_LOG")"
: > "$WLS_LOG"
WLS_UP_FAIL=1 "$REPO/bin/with-local-stack" -- touch "$T/should-not-exist"; st=$?
check "a failing up skips the command, still runs down, and fails" "$([ $st -eq 9 ] && [ ! -e "$T/should-not-exist" ] && [ "$(tr '\n' ' ' < "$WLS_LOG")" = 'up down ' ] && echo 0 || echo 1)" "$(cat "$WLS_LOG")"
unset TOOLING_SUPABASE_LOCAL

echo "ios-sim"
cat > "$STATE/sims.json" <<'EOF'
{"devices": {
  "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
    {"name": "iPhone 16", "udid": "UDID-16", "state": "Shutdown", "isAvailable": true},
    {"name": "iPad", "udid": "UDID-IPAD", "state": "Booted", "isAvailable": true}],
  "com.apple.CoreSimulator.SimRuntime.tvOS-18-0": [
    {"name": "TV", "udid": "UDID-TV", "state": "Booted", "isAvailable": true}]}}
EOF
mkdir -p "$T/sim"
SIMENV=(env -u SIM_UDID -u IOS_SIM_DEVICE TOOLING_APP_ROOT="$T/sim")
out="$(SIM_UDID=FIXED "${SIMENV[@]}" SIM_UDID=FIXED "$REPO/bin/ios-sim" 2>&1)"
check "SIM_UDID wins" "$([ "$out" = FIXED ] && echo 0 || echo 1)" "$out"
: > "$STUB_LOG"
out="$("${SIMENV[@]}" IOS_SIM_DEVICE="iPhone 16" "$REPO/bin/ios-sim" 2>/dev/null)"
check "a named device that is shut down is booted and waited for" "$([ "$out" = UDID-16 ] && grep -q 'simctl boot UDID-16' "$STUB_LOG" && grep -q 'simctl bootstatus UDID-16' "$STUB_LOG" && echo 0 || echo 1)" "$out"
: > "$STUB_LOG"
out="$("${SIMENV[@]}" IOS_SIM_DEVICE=iPad "$REPO/bin/ios-sim" 2>/dev/null)"
check "a named device that is booted is used as is" "$([ "$out" = UDID-IPAD ] && ! grep -q 'simctl boot' "$STUB_LOG" && echo 0 || echo 1)" "$out"
echo 'IOS_SIM_DEVICE=iPhone 16' > "$T/sim/tooling.env"
out="$(env -u SIM_UDID -u IOS_SIM_DEVICE TOOLING_APP_ROOT="$T/sim" "$REPO/bin/ios-sim" 2>/dev/null)"
check "IOS_SIM_DEVICE is read from tooling.env" "$([ "$out" = UDID-16 ] && echo 0 || echo 1)" "$out"
rm "$T/sim/tooling.env"
out="$("${SIMENV[@]}" "$REPO/bin/ios-sim" 2>&1)"
check "falls back to the first booted iOS simulator (not tvOS)" "$([ "$out" = UDID-IPAD ] && echo 0 || echo 1)" "$out"
out="$("${SIMENV[@]}" IOS_SIM_DEVICE=Nope "$REPO/bin/ios-sim" 2>&1)"; st=$?
check "an unknown device is an error" "$([ $st -ne 0 ] && echo 0 || echo 1)" "$out"
echo '{"devices": {}}' > "$STATE/sims.json"
out="$("${SIMENV[@]}" "$REPO/bin/ios-sim" 2>&1)"; st=$?
check "no booted simulator is an error" "$([ $st -ne 0 ] && echo 0 || echo 1)" "$out"

echo "tooling-check"
fixture() { # fixture NAME -> a vendored copy of tests/fixtures/NAME
  local d="$T/fx-$1-$RANDOM"
  cp -R "$REPO/tests/fixtures/$1" "$d"
  "$REPO/bin/tooling-sync" "$d" >/dev/null
  echo "$d"
}
chk() { python3 -I "$REPO/bin/tooling-check" "$1" 2>&1; }

d="$(fixture clean)"; out="$(chk "$d")"; st=$?
check "passes on a clean app" "$([ $st -eq 0 ] && echo 0 || echo 1)" "$out"
d="$(fixture always-pass)"; out="$(chk "$d")"; st=$?
check "fails on an always-pass test target" "$([ $st -ne 0 ] && echo "$out" | grep -q "test-ui-surface" && echo 0 || echo 1)" "$out"
d="$(fixture missing-target)"; out="$(chk "$d")"; st=$?
check "fails on a missing footprint target" "$([ $st -ne 0 ] && echo "$out" | grep -q "'test-device'" && echo 0 || echo 1)" "$out"
d="$(fixture non-phony)"; out="$(chk "$d")"; st=$?
check "fails on a standard target not declared .PHONY (test/ folder fixture)" "$([ $st -ne 0 ] && echo "$out" | grep -q "target 'test' is not declared .PHONY" && ! echo "$out" | grep -q "'test-device' is not" && echo 0 || echo 1)" "$out"
d="$(fixture clean)"; echo '# local edit' >> "$d/tooling/bin/logged"; out="$(chk "$d")"; st=$?
check "fails on an edited vendored file, naming it" "$([ $st -ne 0 ] && echo "$out" | grep -q 'tooling/bin/logged was edited' && echo 0 || echo 1)" "$out"
d="$(fixture clean)"; rm "$d/tooling/bin/ios-sim"; out="$(chk "$d")"; st=$?
check "fails on a missing vendored file, naming it" "$([ $st -ne 0 ] && echo "$out" | grep -q 'tooling/bin/ios-sim is missing' && echo 0 || echo 1)" "$out"
d="$(fixture clean)"; echo x > "$d/tooling/bin/extra"; out="$(chk "$d")"; st=$?
check "fails on an extra vendored file, naming it" "$([ $st -ne 0 ] && echo "$out" | grep -q 'tooling/bin/extra is not part' && echo 0 || echo 1)" "$out"
d="$(fixture clean)"; sed -i.bak '/include tooling/d' "$d/Makefile"; out="$(chk "$d")"; st=$?
check "fails when the Makefile does not include tooling.mk" "$([ $st -ne 0 ] && echo "$out" | grep -q 'does not include' && echo 0 || echo 1)" "$out"
d="$(fixture clean)"; printf 'test-lint:\n\t@lint | tail -3\n' >> "$d/Makefile"; out="$(chk "$d")"; st=$?
check "fails on a pipe into tail without pipefail (any test* target)" "$([ $st -ne 0 ] && echo "$out" | grep -q "test-lint" && echo 0 || echo 1)" "$out"
d="$(fixture clean)"; printf 'test-lint:\n\t@lint || true # tooling: allow-soft\n' >> "$d/Makefile"; out="$(chk "$d")"; st=$?
check "allow-soft exempts a line" "$([ $st -eq 0 ] && echo 0 || echo 1)" "$out"
d="$(fixture clean)"; printf 'release:\n\t@ship || :\n' >> "$d/Makefile"; out="$(chk "$d")"; st=$?
check "fails on '|| :' in a standard target" "$([ $st -ne 0 ] && echo "$out" | grep -q "'release'" && echo 0 || echo 1)" "$out"
d="$(fixture clean)"; rm -rf "$LOCK"; : > "$STUB_LOG"; out="$(cd "$d" && make 2>&1)"; st=$?
check "a bare make starts nothing (default goal is tooling-help)" "$([ $st -eq 0 ] && echo "$out" | grep -q 'Standard targets' && [ ! -s "$STUB_LOG" ] && [ ! -e "$LOCK" ] && echo 0 || echo 1)" "$out"
d="$(fixture clean)"; { echo '.DEFAULT_GOAL := test'; cat "$d/Makefile"; } > "$d/M" && mv "$d/M" "$d/Makefile"; : > "$STUB_LOG"
out="$(cd "$d" && make 2>&1)"
check "a default goal set by the app before the include is kept" "$(echo "$out" | grep -q 'flutter test' && [ ! -s "$STUB_LOG" ] && echo 0 || echo 1)" "$out"
d="$(fixture clean)"; out="$(cd "$d" && make tooling-version)"
check "make tooling-version prints the vendored version" "$([ "$out" = "$(cat "$REPO/VERSION")" ] && echo 0 || echo 1)" "$out"
d="$(fixture clean)"; out="$(cd "$d" && make local-functions ENV=prod 2>&1)"; st=$?
check "local-functions refuses ENV other than local" "$([ $st -ne 0 ] && echo "$out" | grep -q 'only serves the local stack' && echo 0 || echo 1)" "$out"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

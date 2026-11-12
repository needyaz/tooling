# tooling

Shared build, test and local-stack scripts for apps, plus a check that an app follows the same contract. MIT licensed.

An app vendors a copy of this repo into its own `tooling/` directory (with `bin/tooling-sync`) and drives everything through standard `make` targets. Nothing here knows about any particular app.

## Contract

### Standard targets

| Target | Does |
|---|---|
| `setup` | Fetch dependencies, generate code |
| `test` | Fast tests, no device |
| `test-device` | Simulator, emulator and end-to-end tests |
| `local-up` / `local-down` | Disposable local backend stack |
| `screenshots` | Capture store screenshots |
| `listing` | Store listing diff and apply |
| `beta` | Beta channel upload |
| `release` | Store production |
| `deploy-backend` | Migrations and functions for one environment |

An app defines only the targets its footprints need. A standard target and every `test*` target must fail when the thing it runs fails.

### Footprints

`TOOLING_FOOTPRINTS` in `tooling.env` lists what the app is. In v0.1.0 the check requires:

| Footprint | Required targets |
|---|---|
| `flutter` | `test`, `test-device` |
| `supabase` | `local-up`, `local-down` |

Other footprints are accepted and not checked yet. The rest of the standard list arrives in later versions.

### `tooling.env`

Lives in the app root, never in this repo. Plain `KEY=VALUE` lines with no quotes. Read by make (`-include`) and by the bash scripts, which read it themselves because make 3.81 (the macOS default) does not pass make variables to `$(shell ...)`. The environment overrides the file.

```
TOOLING_FOOTPRINTS=flutter supabase
SUPABASE_LOCAL_ID=exampleapp-local
SUPABASE_FUNCTIONS_SRC=supabase/functions
SUPABASE_NO_JWT_FUNCTIONS=fn-version some-webhook
SUPABASE_LOCAL_AFTER_UP=bash supabase/scripts/local_guard.sh seed
IOS_SIM_DEVICE=iPhone 17 Pro
```

| Key | Meaning |
|---|---|
| `TOOLING_FOOTPRINTS` | Space-separated footprints |
| `SUPABASE_LOCAL_ID` | Stack name, used in container names (default `<app dir>-local`) |
| `SUPABASE_LOCAL_URL` | API URL, loopback only (default `http://127.0.0.1:54321`) |
| `SUPABASE_FUNCTIONS_SRC` | Edge functions directory (default `supabase/functions`) |
| `SUPABASE_NO_JWT_FUNCTIONS` | Functions served without JWT verification |
| `SUPABASE_FUNCTIONS_PROBE` | Function polled until it answers 200 (default `fn-version`) |
| `SUPABASE_LOCAL_EXCLUDE` | Services not started (default `studio,imgproxy,mailpit,logflare,vector,postgres-meta`) |
| `SUPABASE_LOCAL_AFTER_UP` | Command run in the app root after `local-up`, for example seeding |
| `IOS_SIM_DEVICE` | Simulator name for `ios-sim` |
| `TOOLING_LOCK_DIR` | Machine-wide locks (default `~/.cache/tooling/locks`) |
| `TOOLING_LOCK_TIMEOUT` / `TOOLING_LOCK_INTERVAL` | Seconds to wait for the stack lock (900) and between tries (5) |
| `TOOLING_LOCK_STALE_AFTER` | Seconds before a lock whose container is not running is broken (300) |

### App Makefile

```make
include tooling/mk/tooling.mk

.PHONY: test test-device
test:
	flutter test
test-device:
	tooling/bin/with-local-stack -- ...
```

`tooling.mk` reads `tooling.env`, includes `mk/supabase-local.mk` when the footprints have `supabase`, and defines `tooling-check` and `tooling-version`.

## Vendoring

```
tooling/bin/tooling-sync ../my-app      # from a checkout of this repo
```

Copies `VERSION`, `README.md`, `mk/` and `bin/` into `my-app/tooling/`, removes files that are no longer shipped and writes `tooling/MANIFEST` (sha256 per file). Commit the result. Never edit files under `tooling/`; change this repo and sync again. `make tooling-check` fails on any local edit, missing file or extra file.

## Commands

| Command | Does |
|---|---|
| `bin/supabase-local` | The local Supabase stack: `up`, `down`, `status`, `url`, `key`, `servicekey`, `container`, `guard-file`, `workdir`, `abs-workdir`, `lock`, `unlock`, `functions-up`, `functions-down`, `functions-status`, `admin-secret`, `db` |
| `bin/with-local-stack [--functions] -- CMD` | Up, run CMD, always down; exits with CMD's status |
| `bin/logged NAME -- CMD` | Full output to `build/logs/NAME-<timestamp>-<pid>.log` (never overwritten); prints `✓`/`✗`, duration and the log path; exits with CMD's status |
| `bin/ios-sim` | Prints a simulator UDID: `$SIM_UDID`, else the device named `$IOS_SIM_DEVICE` (booted if needed), else the first booted iOS simulator |
| `bin/xcuitest NAME -- ARGS` | `xcodebuild test ARGS` with the log kept, only `Test Case` / `Test Suite` / `error:` lines shown, xcodebuild's status, fails when no tests ran |
| `bin/tooling-check [APP_DIR]` | The conformance check (python3, standard library only) |
| `bin/tooling-sync APP_DIR` | Vendor this repo into an app |

### Local stack notes

- One stack at a time: every local stack uses the same default ports, so each holds a machine-wide lock. A lock whose database container is not running and which is older than `TOOLING_LOCK_STALE_AFTER` is broken.
- `local-up` starts from a generated copy of `supabase/config.toml` in `build/local-supabase/` with boot migrations off. The app's `config.toml` is never changed.
- `local-functions` serves the app's functions with fake per-run secrets (`FN_VERSION`, `ADMIN_SECRET`) and no provider keys. It refuses an explicit `ENV` other than `local`.
- Nothing links, logs in or contacts a remote project.

## `tooling-check`

Fails when:

- `tooling/MANIFEST` does not match the vendored files (each edited, missing or extra file is named).
- The Makefile does not include `tooling/mk/tooling.mk`.
- A standard target required by a footprint is not defined. Targets are read with `make -pRrq`, which runs no recipe.
- A `test*` or standard target swallows failure: its recipe has `|| true` or `|| :`, or pipes into `grep`, `tee`, `tail` or `head` on a line without `pipefail` or `PIPESTATUS`. A line ending in `# tooling: allow-soft` is exempt.

## Development

```
tests/run.sh
```

Runs offline, with stubs for docker, supabase, xcodebuild and xcrun. Fixture apps for the check live in `tests/fixtures/`. Bump `VERSION` and tag a release when the shipped files change.

## Gotchas

- macOS ships GNU Make 3.81.
- `make -n` still runs recipe lines that contain `$(MAKE)`. Keep `$(MAKE)` off lines with side effects, or use a literal `make`.

# Changelog

## 0.2.0

### Added

- The remote desktop size is now a per-connection setting
  ([#8](https://github.com/cahva/omarchy-rdp-manager/issues/8)). Nothing emitted
  a `/size`, so FreeRDP fell back to its own default of 1024x768. On a 5120x1440
  monitor at scale 1.25 that is an 819x614 window in the corner, with no way to
  fix it short of turning on dynamic resolution.
- `resolution` is `auto` or `WIDTHxHEIGHT`, offered in the form as a dropdown of
  common sizes plus a custom field. `auto` matches the monitor the session opens
  on, clamped to 2560x1440. Each axis is clamped separately, so an ultrawide
  asks for 2560x1440 rather than the 2560x720 that preserving its aspect ratio
  would give.
- `displayMode` decides what resizing the window does: `fixed` letterboxes,
  `scaled` scales the desktop with `/smart-sizing`, and `dynamic` renegotiates
  it with `+dynamic-resolution` as before. `scaled` is new, and it is the way to
  get a resizable window without involving the server's display driver.

### Changed

- `displayMode` replaces the `dynamicResolution` boolean in the form. Existing
  files are unaffected: the boolean is still read, with `true` meaning
  `dynamic`, `false` meaning `fixed`, and absent meaning `dynamic`, which is
  what the old default did. New connections are created as `fixed`, since an
  auto-sized window no longer needs dynamic resolution just to be usable.

FreeRDP exits 22 if `/smart-sizing` and `+dynamic-resolution` are both passed,
so the launcher and `Model.js` emit exactly one of them, and both test suites
assert it.

## 0.1.2

### Fixed

- Disconnect could send `SIGTERM` to an unrelated process
  ([#3](https://github.com/cahva/omarchy-rdp-manager/issues/3)). The pid in a session
  state file was checked with `kill -0` and nothing else, which proves only that *some*
  process holds that pid. A launcher that died without writing a terminal state left the
  pid behind, and once the kernel recycled it, Disconnect signalled whatever now owned it.
- The status helper had the mirror problem: it reaped a stale state file only when
  `kill -0` failed, so a recycled pid kept a phantom session in the panel indefinitely,
  reported as "connecting" because no matching window exists.
- Sessions now record the launcher's process start time (field 22 of `/proc/<pid>/stat`,
  boot-relative and monotonic) alongside the pid, and both must match before a session
  counts as live or is signalled.

A state file written by 0.1.1 or earlier has no recorded start time and cannot be
verified, so it is treated as not ours: a session running across the upgrade is reported
as ended and must be closed from its own window. Session state lives in
`$XDG_RUNTIME_DIR`, so this resolves itself at the next reboot.

## 0.1.1

### Fixed

- `bin/omarchy-rdp-secret` reported success when a keyring write failed
  ([#1](https://github.com/cahva/omarchy-rdp-manager/issues/1)). `$?` was captured
  inside `if ! …; then`, which yields the status of the negation — always `0` when the
  command failed — and that `0` was passed to `die`, so the helper exited 0. The panel
  branches on the exit status, so it marked the connection as having a stored password
  and closed the form while the keyring held nothing, or the previous credential.
  Connecting then failed with "no password stored", or silently used the old password.
- The same mistake in the `lookup` branch made its `124` timeout case unreachable, so a
  locked keyring was reported as "no password stored yet" instead of saying the keyring
  did not respond.
- `die` now refuses to exit 0, so an error path cannot report success even if a status
  is miscomputed again.

Reaching either bug required the keyring to be locked or otherwise failing, which is why
normal use never showed it.

## 0.1.0

First release. The plugin id is `io.github.cahva.rdp-manager`.

- Bar icon reflecting live session state: idle, connecting, connected (with a
  count), and a tinted icon when the last attempt failed.
- Panel to list, create, edit and delete saved connections, with multiple drive
  mappings per connection.
- Passwords stored in `gnome-keyring` and passed to FreeRDP over `/args-from:fd:3`,
  so they never appear in `ps`, the environment, or a file.
- Connections kept in hand-editable `~/.config/omarchy-rdp/connections.json`, picked
  up live on external edits.
- Session state detected from the launcher process plus the `omarchy-rdp-<id>` window
  class, so *connecting* and *connected* are distinguished properly.
- Sessions started detached, surviving shell restarts and plugin hot-reloads.
- Standalone CLI helpers under `bin/` for connecting, probing, status and disconnect.
- `+auth-only` test probe, run only on explicit request.
- Focusing a session goes through `bin/omarchy-rdp-focus`, which uses Hyprland
  0.56's Lua dispatcher. The pre-0.56 `hyprctl dispatch focuswindow class:...` form
  is a Lua syntax error on 0.56 and failed silently, so the Focus button did
  nothing; the legacy call is kept only as a fallback for older Hyprland.
- Session state directory must be owned by the current user and mode `0700`, and is
  never `/tmp`. `omarchy-rdp-disconnect` reads a pid from a file there and signals
  it, so a directory another local user could write to would let them pick the
  target.

# Changelog

## 0.2.1

### Fixed

- A session that dropped mid-use was reported as a connect-time problem
  ([#7](https://github.com/cahva/omarchy-rdp-manager/issues/7)). A session that
  had been up for nearly two hours was reset by the server, FreeRDP exited 147,
  and the panel said "Transport failed, is that port really RDP?" in red with a
  critical notification. The port had been right all along. Exit 147 covers both
  "the socket opened but nothing there speaks RDP" and "an established link
  died", and nothing distinguished them.
- Sessions now record whether their window ever appeared. FreeRDP maps nothing
  until the connection succeeds, so that is the signal, and it has to be watched
  for while the session is alive: by the time the exit message is written the
  window is gone. A session that established and then failed now reads
  "Connection lost", in the same neutral tone as a deliberate disconnect, and no
  longer tints the bar icon or raises a critical notification. A link that dies
  is worth reporting, not worth painting as something you misconfigured.
- **Eight of the fourteen exit-code messages named the wrong thing.** Both
  tables were derived from "FreeRDP reports failures as `135 + low byte of
  ERRCONNECT_*`". That holds up to 143 and then breaks, because the real
  `enum XF_EXIT_CODE` is bespoke and skips 146. So 144 said "Authentication
  failed" when it means insufficient privileges, 156 said "Wrong password" when
  it means an account restriction, and 159 said "Account locked out" when it
  means no credentials were supplied. The table is now transcribed from the enum
  at FreeRDP 3.30.0.
- Codes 1 to 11 were not mapped at all, and they are the ones that describe how
  a *live* session ended: a remote sign-out, an idle timeout, being replaced by
  another connection. Those showed as "Could not start FreeRDP (exit 2)". They
  are named now, and the ones that are ordinary endings no longer count as
  failures.
- `isFailureExit` no longer treats 130 as Ctrl-C. The launcher already records a
  deliberate stop as phase `stopped` with exit 0, so a 130 reaching that
  function could only ever be `XF_EXIT_PROTOCOL`, and the exception hid it.

### Added

- `tests/launcher.test.sh` now asserts the two exit-code tables agree. They are
  written twice, in `Model.js` and in the launcher, and they had already drifted
  once, so the duplication gets a test rather than a comment.

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
- Under `dynamic` the picker is labelled **Starting size**, because the desktop
  is renegotiated on the first resize and the value only decides where the
  window opens. It is still honoured in that mode: dropping it would put every
  dynamic session back at FreeRDP's 1024x768 default, and legacy files have no
  `displayMode`, so they read as `dynamic` and hand-editing a size there would
  otherwise do nothing.

### Fixed

- The Hyprland window rules in the README used `windowrulev2` in
  `hyprland.conf`. Omarchy 4 configures Hyprland in Lua, so that syntax does
  nothing. They are now `o.window(...)` calls, with a `center` rule, since
  without one a floating session opens in the corner of a large monitor. The
  patterns end in `.*`: Hyprland matches against the whole class, so a bare
  `"^omarchy-rdp-"` prefix matches nothing and fails silently. They set only
  `center`, not `float`: FreeRDP marks a fixed or scaled desktop as
  non-resizable so Hyprland floats it anyway, while a dynamic desktop is
  resizable and tiles, which is what you want there.
- The README said plugin files hot-reload when saved. Omarchy starts Quickshell
  with `QS_DISABLE_FILE_WATCHER=1`, so QML does not: `omarchy restart shell` is
  required after a `.qml` change, and neither `rescanPlugins` nor disabling and
  re-enabling the plugin is enough, because Qt caches compiled types by URL for
  the life of the process.

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

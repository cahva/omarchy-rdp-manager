# Changelog

## 0.1.0

First release.

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

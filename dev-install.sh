#!/usr/bin/env bash
# Copy this working tree into the live Omarchy plugin directory and reload it.
#
# The shell only discovers plugins exactly one level under
# ~/.config/omarchy/plugins/, so a repo kept elsewhere needs this step. A symlink
# is not a substitute: the `inotifywait -r` watcher the shell uses for hot-reload
# does not follow one, so edits would silently stop being picked up.
#
# Once installed, saving any file in the plugin directory hot-reloads it — so for
# a tight loop, run this once and then edit the installed copy, or re-run it after
# each change here.
set -euo pipefail

PLUGIN_ID=cahva.rdp-manager
SRC=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"

mkdir -p "$DEST"
rsync -a --delete \
  --exclude '.git/' \
  --exclude '.github/' \
  --exclude 'node_modules/' \
  "$SRC/" "$DEST/"

printf 'installed %s -> %s\n' "$PLUGIN_ID" "$DEST"

if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  omarchy-plugin-validate "$DEST" || { printf 'manifest validation failed\n' >&2; exit 1; }
fi

# rescanPlugins re-walks the plugin dirs and hot-reloads plugin code. It needs a
# running shell; outside a session this is expected to fail, so do not treat it
# as fatal.
if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 \
    && printf 'shell reloaded\n' \
    || printf 'could not reach omarchy-shell (is the shell running?)\n' >&2
fi

printf '\nEnable it with:  omarchy plugin enable %s right\n' "$PLUGIN_ID"

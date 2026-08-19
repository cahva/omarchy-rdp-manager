# Shared state-directory resolution for the omarchy-rdp helpers.
# Sourced, never executed — deliberately not marked executable.
#
# omarchy-rdp-disconnect reads a pid out of a file in this directory and sends it
# SIGTERM, so a state directory that another local user can write to is a way to
# make this plugin signal an arbitrary process. That is why /tmp is never used as
# a fallback: it is world-writable, so a pre-created /tmp/omarchy-rdp would be
# trusted on sight. The runtime directory is per-user and mode 0700.

# Print the state directory, or fail with a message if there is no usable one.
rdp_state_dir() {
  local dir=${OMARCHY_RDP_STATE_DIR:-}
  if [[ -z $dir ]]; then
    local runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    if [[ ! -d $runtime ]]; then
      printf 'no runtime directory at %s; set XDG_RUNTIME_DIR\n' "$runtime" >&2
      return 1
    fi
    dir="$runtime/omarchy-rdp"
  fi
  printf '%s' "$dir"
}

# Confirm an existing state directory is ours and private. Returns non-zero (with
# a message) when it is not, so callers can refuse rather than trust it. A
# missing directory is not an error here — readers treat that as "no sessions"
# and the launcher creates it.
rdp_state_dir_ok() {
  local dir=$1 owner mode
  [[ -d $dir ]] || return 1
  if [[ -L $dir ]]; then
    printf 'refusing symlinked state directory: %s\n' "$dir" >&2
    return 1
  fi
  owner=$(stat -c %u "$dir" 2>/dev/null) || return 1
  mode=$(stat -c %a "$dir" 2>/dev/null) || return 1
  if [[ $owner != "$(id -u)" ]]; then
    printf 'state directory %s is not owned by this user\n' "$dir" >&2
    return 1
  fi
  if [[ $mode != 700 ]]; then
    printf 'state directory %s must be mode 700, found %s\n' "$dir" "$mode" >&2
    return 1
  fi
  return 0
}

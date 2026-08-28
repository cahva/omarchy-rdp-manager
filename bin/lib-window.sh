# shellcheck shell=bash
# Shared window lookup for the omarchy-rdp helpers.
# Sourced, never executed, so deliberately not marked executable.
#
# A session's window is the only trustworthy "the connection actually
# succeeded" signal: FreeRDP maps nothing on a pre-connect, TLS or
# authentication failure, so a window existing means the session really got in.
# The class comes from /wm-class, which the launcher sets to omarchy-rdp-<id>.

# Print every mapped window class, one per line, deduplicated. Callers treat no
# windows and no usable hyprctl the same way, so both give empty output.
rdp_window_classes() {
  local hyprctl=${HYPRCTL:-/usr/bin/hyprctl} jq=${JQ:-/usr/bin/jq}
  [[ -x $hyprctl && -x $jq ]] || return 1
  # `initialClass` is the class at map time, which is what /wm-class sets, so it
  # stays right even if something changes the class later. Both are read because
  # these are XWayland windows.
  "$hyprctl" clients -j 2>/dev/null \
    | "$jq" -r '.[] | .initialClass, .class' 2>/dev/null \
    | sort -u
}

# Whether class $1 appears in the newline-separated list $2.
rdp_class_present() {
  local class=$1 classes=${2-}
  [[ -n $class && -n $classes ]] || return 1
  printf '%s\n' "$classes" | grep -Fxq -- "$class"
}

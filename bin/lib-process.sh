# shellcheck shell=bash
# Process identity helpers for the omarchy-rdp helpers.
# Sourced, never executed. Deliberately not marked executable.
#
# A pid on its own is not an identity. `kill -0 $pid` proves only that some
# process has that pid and that we are allowed to signal it, and pids are
# recycled. So a state file left behind by a launcher that died without writing a
# terminal state can name a pid that now belongs to something else entirely.
#
# The start time in /proc/<pid>/stat closes that gap: it is measured in clock
# ticks since boot and never decreases, so a recycled pid always carries a
# different value. Recording it next to the pid turns "a process exists" into
# "our process is still alive".

# Print the start time of a pid, or fail if it cannot be read.
rdp_start_ticks() {
  local pid=$1 raw rest
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  raw=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1

  # Field 2 is the executable name in parentheses and may itself contain spaces
  # and parentheses, which is why this strips to the *last* ') ' rather than
  # splitting the line: for a process named `we ird) name`, a plain
  # `awk '{print $22}'` returns field 1 of the wrong offset. Everything after the
  # strip is numeric, so the last ') ' is always the one closing the name.
  rest=${raw##*') '}
  # shellcheck disable=SC2086  # deliberate word splitting on a known-numeric tail
  set -- $rest

  # The remainder begins at field 3, so field 22 is the 20th token.
  [[ $# -ge 20 ]] || return 1
  printf '%s' "${20}"
}

# Confirm a pid still belongs to the process a state file was written for.
# An empty expected value means the state file predates this check, so it cannot
# be verified and must not be trusted.
rdp_same_process() {
  local pid=$1 expected=$2 actual
  [[ -n $expected && $expected != "null" && $expected != "0" ]] || return 1
  actual=$(rdp_start_ticks "$pid") || return 1
  [[ $actual == "$expected" ]]
}

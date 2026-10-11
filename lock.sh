#!/usr/bin/env bash
# Takes and releases a lock that every runner on the machine shares.
# The command is acquire, run or release. LOCK_NAME names the lock and LOCK_RUN holds the script.

set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

action="${1:-}"
name="${LOCK_NAME:-}"

case "$name" in
  "" | *[!A-Za-z0-9._-]*) fail "Lock name must only use letters, digits, '.', '_' and '-'" ;;
esac

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  MINGW* | MSYS* | CYGWIN*) os=windows ;;
  *) fail "Unsupported platform $(uname -s)" ;;
esac

root="$HOME/.lock-action"
lock="$root/$name.lock"
turn="$root/$name.turn"

powershell_run() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    powershell.exe -NoProfile -NonInteractive -Command "$1" | tr -d '\r'
}

# Prints the pid of a process and a token for when it started, which together identify it.
# Returns 1 when there is no such process and 2 when that could not be determined.
process_id() {
  local pid="$1" id stat started fields status=0
  case "$os" in
    linux)
      [ -d "/proc/$pid" ] || return 1
      stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 2
      # The name may hold spaces, so the fields are counted from the state that follows it
      read -r -a fields <<< "${stat##*) }"
      echo "$pid ${fields[19]}"
      ;;
    macos)
      started="$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null)" || status=$?
      case "$status" in
        0) ;;
        1) return 1 ;;
        *) return 2 ;;
      esac
      # shellcheck disable=SC2086
      echo "$pid" $started
      ;;
    windows)
      id="$(powershell_run "\$process = Get-CimInstance Win32_Process \
        -Filter 'ProcessId=$pid' -ErrorAction Stop; \
        if (\$process) { '{0} {1}' -f \$process.ProcessId, \$process.CreationDate.ToFileTimeUtc() } \
        else { 'gone' }")" || return 2
      case "$id" in
        gone) return 1 ;;
        "$pid "*) echo "$id" ;;
        *) return 2 ;;
      esac
      ;;
  esac
}

# Prints the id of the runner process that the job runs under, which outlives every step.
job_process() {
  local pid=$$ process parent stat fields
  if [ "$os" = windows ]; then
    powershell_run "\$process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + \$PID); \
      for (\$depth = 0; \$process -and \$process.Name -ne 'Runner.Worker.exe' -and \$depth -lt 32; \$depth++) { \
        \$process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + \$process.ParentProcessId) }; \
      if (\$process -and \$process.Name -eq 'Runner.Worker.exe') { \
        '{0} {1}' -f \$process.ProcessId, \$process.CreationDate.ToFileTimeUtc() }"
    return
  fi
  while [ "$pid" -gt 1 ]; do
    if [ "$os" = linux ]; then
      process="$(cat "/proc/$pid/comm")"
      stat="$(cat "/proc/$pid/stat")"
      read -r -a fields <<< "${stat##*) }"
      parent="${fields[1]}"
    else
      process="$(ps -o comm= -p "$pid")"
      parent="$(ps -o ppid= -p "$pid")"
    fi
    if [ "${process##*/}" = Runner.Worker ]; then
      process_id "$pid"
      return
    fi
    pid=$((parent))
  done
  return 1
}

# Prints the process that holds the lock, or nothing when no process has claimed it yet.
holder() {
  local line=""
  { IFS= read -r line < "$lock/owner"; } 2> /dev/null || true
  echo "$line"
}

# Succeeds only when the process is known to have ended, so a failed check never frees a lock.
ended() {
  local id status=0
  [[ "$1" =~ ^[0-9]+\ [^\ ] ]] || return 1
  id="$(process_id "${1%% *}")" || status=$?
  case "$status" in
    # The pid can have passed to a process that started later
    0) [ "$id" != "$1" ] ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
}

# Removes the lock when the job that took it has ended. Waiters take turns at this, and the one
# with the turn looks at the holder again, so a lock that was just taken is never removed.
remove_stale() {
  local owner removed=1
  if ! mkdir "$turn" 2> /dev/null; then
    # A waiter that was killed during its turn never gave it up
    if [ -n "$(find "$turn" -maxdepth 0 -mmin +1 2> /dev/null)" ]; then
      rmdir "$turn" 2> /dev/null || true
    fi
    return 1
  fi
  owner="$(holder)"
  if [ -n "$owner" ]; then
    if ended "$owner"; then
      rm -rf "$lock"
      removed=0
    fi
  elif [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2> /dev/null)" ]; then
    # The taker was killed before it could claim the lock
    rm -rf "$lock"
    removed=0
  fi
  rmdir "$turn"
  return "$removed"
}

acquire() {
  local owner waiting="-" tries=0
  mkdir -p "$root"
  [ -w "$root" ] || fail "Cannot write to $root"
  until mkdir "$lock" 2> /dev/null; do
    owner="$(holder)"
    if [ "$owner" = "$job" ]; then
      echo "This job already holds the $name lock"
      held=1
      return
    fi
    # The holder is only checked now and then, as the check is slow on Windows
    if [ $((tries % 10)) -eq 0 ] && remove_stale; then
      echo "Removed the $name lock that a job left behind"
      continue
    fi
    if [ "$owner" != "$waiting" ]; then
      echo "Waiting for the $name lock${owner:+ held by $(sed -n 2p "$lock/owner" 2> /dev/null)}"
      waiting="$owner"
    fi
    sleep 1
    tries=$((tries + 1))
  done
  # The owner appears in one step, so a waiter never reads part of it
  printf '%s\n%s\n' "$job" \
    "${GITHUB_REPOSITORY:-unknown} run ${GITHUB_RUN_ID:-unknown} on ${RUNNER_NAME:-unknown}" \
    > "$lock/owner.new"
  mv "$lock/owner.new" "$lock/owner"
  echo "Acquired the $name lock"
}

release() {
  if [ "$(holder)" != "$job" ]; then
    echo "This job does not hold the $name lock"
    return
  fi
  rm -rf "$lock"
  echo "Released the $name lock"
}

job="$(job_process)" || job=""
[ -n "$job" ] || fail "Could not find the runner process of the job"
held=""

case "$action" in
  acquire)
    acquire
    ;;
  run)
    acquire
    status=0
    "$BASH" --noprofile --norc -e -o pipefail -c "${LOCK_RUN:?}" || status=$?
    # A lock that an earlier step took stays with the job
    [ -n "$held" ] || release
    exit "$status"
    ;;
  release)
    release
    ;;
  *)
    fail "Unknown command '$action'"
    ;;
esac

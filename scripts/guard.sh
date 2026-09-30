#!/usr/bin/env bash
# Run a command with its output in a log file, a limit on total time, and a
# limit on how long it may go without printing anything. Either limit kills the
# command and everything it started. Prints the end of the log, then one line
# saying how it ended, and exits with the command's status (124 on the time
# limit, 125 on silence).
#
#   scripts/guard.sh [--timeout S] [--stall S] [--log FILE] [--tail N] -- command...
#
# Defaults: 300 s total, 90 s of silence, the last 40 lines. stdin is /dev/null,
# so a command that stops to ask a question fails instead of waiting forever.
# macOS has no `timeout`; this is what to use instead.
set -u

timeout=300
stall=90
log=""
tail_lines=40
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) timeout=$2; shift 2 ;;
    --stall) stall=$2; shift 2 ;;
    --log) log=$2; shift 2 ;;
    --tail) tail_lines=$2; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
if [ $# -eq 0 ]; then
  echo "usage: scripts/guard.sh [--timeout S] [--stall S] [--log FILE] [--tail N] -- command..." >&2
  exit 2
fi
[ -n "$log" ] || log=$(mktemp "${TMPDIR:-/tmp}/guard.XXXXXX")
: > "$log"

# Its own process group, so a kill reaches the children too (npm → node →
# workerd).
perl -e 'setpgrp(0, 0); exec @ARGV or die "guard: cannot run $ARGV[0]: $!\n"' -- "$@" > "$log" 2>&1 < /dev/null &
pid=$!

start=$(date +%s)
last_size=0
last_change=$start
reason=""
status=0
while kill -0 "$pid" 2>/dev/null; do
  sleep 1
  now=$(date +%s)
  size=$(wc -c < "$log" | tr -d ' ')
  if [ "$size" != "$last_size" ]; then
    last_size=$size
    last_change=$now
  fi
  if [ $((now - start)) -ge "$timeout" ]; then
    reason="killed: over ${timeout}s"; status=124; break
  fi
  if [ $((now - last_change)) -ge "$stall" ]; then
    reason="killed: no output for ${stall}s"; status=125; break
  fi
done

if [ -n "$reason" ]; then
  # Out of the job table first, or bash reports the kill on its own line.
  disown "$pid" 2>/dev/null
  kill -TERM -- "-$pid" 2>/dev/null
  sleep 2
  kill -KILL -- "-$pid" 2>/dev/null
else
  wait "$pid"
  status=$?
  reason="exited"
fi

tail -n "$tail_lines" "$log"
echo "── guard: $reason · status $status · $(( $(date +%s) - start ))s · log $log"
exit "$status"

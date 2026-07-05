#!/bin/bash
# memtrace.sh — catch the memory spike with an exact allocation backtrace.
#
# Usage:
#   1. Quit Goel° if it's running.
#   2. Run:  ./Scripts/memtrace.sh
#   3. Reproduce the action that made RAM balloon (browse a big SFTP dir,
#      start a torrent, open a huge playlist, etc.).
#   4. When RSS crosses the threshold below, this prints the top allocation
#      backtraces — the exact call stacks holding the memory — and exits.
#
# MallocStackLogging records a stack for every live allocation, so the app
# uses more RAM while tracing (that's expected) — we only care about WHERE.

set -euo pipefail

APP="/Applications/Goel°.app/Contents/MacOS/GoelDownloader"
THRESHOLD_MB=${1:-400}          # trip point in MB (default 400)

echo "Launching under MallocStackLogging (threshold ${THRESHOLD_MB} MB)…"
MallocStackLogging=1 MallocStackLoggingNoCompact=1 "$APP" &
PID=$!
echo "PID $PID — now reproduce the action that grows memory."

while kill -0 "$PID" 2>/dev/null; do
  RSS_KB=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ' || echo 0)
  RSS_MB=$(( RSS_KB / 1024 ))
  printf "\rRSS: %5d MB" "$RSS_MB"
  if (( RSS_MB >= THRESHOLD_MB )); then
    echo -e "\n⚠️  Crossed ${THRESHOLD_MB} MB — capturing top allocation backtraces…"
    malloc_history "$PID" -highWaterMark 2>/dev/null | head -120 || \
      malloc_history "$PID" -allBySize 2>/dev/null | head -120
    echo -e "\nDone. Full dump:  malloc_history $PID -allBySize"
    exit 0
  fi
  sleep 1
done
echo -e "\nApp exited before crossing threshold."

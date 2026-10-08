#!/usr/bin/env bash

# This script is a wrapper for other programs
# that ensures they're killed when stdin closes
# (eg: a job terminates), along with any programs
# they started (eg: yt-dlp's ffmpeg)

# Start the program in the background. Job control
# puts it in its own process group so the whole group
# can be killed. Its stdin stays /dev/null, as it is
# for background programs without job control
set -m
exec "$@" </dev/null &
pid1=$!
set +m

# Silence warnings from here on
exec >/dev/null 2>&1

# Read from stdin in the background and kill the
# program's process group when stdin closes
(
  while read -r; do :; done
  kill -KILL -- "-$pid1"
) <&0 &
pid2=$!

# Clean up. The program's exit status is passed on
# (128 + the signal's number if it was killed)
wait "$pid1"
ret=$?
kill -KILL "$pid2"
wait "$pid2"
exit "$ret"

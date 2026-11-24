#!/bin/sh
# IN-09: Ctrl+C must reach the foreground process group as SIGINT.
trap ': > "$AIBCC_SIGNAL_FILE"; exit 130' INT
printf 'waiting for SIGINT\r\n'
: > "$AIBCC_READY_FILE"
while :; do sleep 0.1; done

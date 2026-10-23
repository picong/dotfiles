#!/usr/bin/env bash
# Ensure exactly one foot terminal server is running.
# Idempotent: starts a server only if none exists. Safe to call repeatedly
# (e.g. at niri startup or after a config reload).

if ! pgrep -f 'foot --server' >/dev/null 2>&1; then
    foot --server &
    disown
fi

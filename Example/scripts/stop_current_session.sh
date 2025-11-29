#!/bin/zsh

# Hacky script to kill any existing LLDB sessions in the event where the user runs the debug task again.
# This is because I could not find any realiable way to have Cursor itself do this natively. Probably need
# to write an actual extension to cover these bits.

# FIXME: We don't know the PID of the actual session, so we're killing everything which is not ideal.
pgrep -f "lldb-dap" | xargs kill -9 || true

# Need to give Cursor some time, otherwise it thinks the session is still running.
sleep 1
#!/bin/sh
# Loads install.sh's functions - without running main() - and evaluates the
# snippet passed as $1.
#
# This exists so every PATH/HOME/SHELL-dependent probe runs in a CHILD process.
# A shell caches where it found a command, so flipping PATH inside the test
# process and re-probing can keep answering from the cache and quietly report
# the machine's real python3 instead of the fixture. The tests pair this with
# controls that must fail, so a broken isolation shows up as a failure rather
# than as a suite that passes for the wrong reason.
set -u

LIB="${DOUGH_TEST_LIB:?DOUGH_TEST_LIB is not set}"
# shellcheck disable=SC1090  # path is supplied by the harness at runtime
. "$LIB"

# A snippet evaluated against no functions at all would print nothing and look
# like a well-behaved "false". Refuse to run instead.
if ! command -v python3_ready >/dev/null 2>&1; then
  echo "LIB-NOT-LOADED"
  exit 99
fi

eval "$1"

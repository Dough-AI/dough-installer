#!/usr/bin/env bash
# Unit tests for install.sh's helpers. Runs on macOS with the system bash.
#
#   bash test/install.sh.tests.sh
#
# The script under test is POSIX sh; only this harness needs bash.
#
# Everything PATH-, HOME- or SHELL-dependent is probed in a child process (see
# probe.sh) and every such group carries a CONTROL that must come out the other
# way. A probe that silently answered from the machine's real environment would
# make the whole group vacuous, and the control is the only thing that notices.
# Single quotes are load-bearing throughout: a quoted snippet is evaluated in the
# CHILD shell, not here, and the profile-line expectations are literal $HOME /
# $PATH text that must survive into a shell profile unexpanded.
# shellcheck disable=SC2016
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
script="$root/install.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- load the functions without running main() ------------------------------
lib="$work/lib.sh"
grep -vxF 'main "$@"' "$script" >"$lib"
removed=$(($(wc -l <"$script") - $(wc -l <"$lib")))
if [ "$removed" -ne 1 ]; then
  echo "FATAL: expected to strip exactly the 'main \"\$@\"' line, stripped $removed" >&2
  exit 1
fi

export DOUGH_TEST_LIB="$lib"
probe="$here/probe.sh"

pass=0
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
    pass=$((pass + 1))
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

# Run a snippet in a child sh with a scrubbed environment. Extra assignments are
# passed as leading VAR=VALUE arguments.
run() { # run <snippet> [VAR=VALUE ...]
  local snippet="$1"
  shift
  env -i \
    "PATH=${TEST_PATH:-/usr/bin:/bin}" \
    "HOME=${TEST_HOME:-$work/home}" \
    "SHELL=${TEST_SHELL:-/bin/zsh}" \
    "DOUGH_TEST_LIB=$lib" \
    "TMPDIR=$work" \
    "$@" \
    /bin/sh "$probe" "$snippet" 2>/dev/null
}

boolean() { # boolean <function-call-or-expression>
  run "if $1; then echo true; else echo false; fi"
}

# The exit status of the child. Needed wherever the code under test calls fail(),
# which exits the process - an `if` wrapped around it never gets to report.
status() { # status <snippet> [VAR=VALUE ...]
  run "$@" >/dev/null 2>&1
  echo $?
}

stderr() { # stderr <snippet> [VAR=VALUE ...]
  local snippet="$1"
  shift
  # `2>&1 >/dev/null` keeps ONLY stderr, which is the point here.
  # shellcheck disable=SC2069
  env -i \
    "PATH=${TEST_PATH:-/usr/bin:/bin}" \
    "HOME=${TEST_HOME:-$work/home}" \
    "SHELL=${TEST_SHELL:-/bin/zsh}" \
    "DOUGH_TEST_LIB=$lib" \
    "TMPDIR=$work" \
    "$@" \
    /bin/sh "$probe" "$snippet" 2>&1 >/dev/null
}

# Writes an executable shim at $1 that prints $2 and exits 0.
shim() {
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\necho %s\n' "$2" >"$1"
  chmod +x "$1"
}

echo
echo "install.sh helpers"

# --- is_clt_stub ------------------------------------------------------------
echo
echo "is_clt_stub - which executables are unsafe to run blind"
check "/usr/bin/python3 is the stub" "true" "$(boolean 'is_clt_stub /usr/bin/python3')"
check "/usr/bin/git is the stub" "true" "$(boolean 'is_clt_stub /usr/bin/git')"
check "Homebrew python3 is not" "false" "$(boolean 'is_clt_stub /opt/homebrew/bin/python3')"
check "a tool inside the installed CLT is not" "false" \
  "$(boolean 'is_clt_stub /Library/Developer/CommandLineTools/usr/bin/git')"

# --- the guard: never execute the stub --------------------------------------
# The consequence of getting this wrong is a GUI dialog on a client's machine,
# so assert the SIDE EFFECT: the interpreter must not have been run at all.
echo
echo "python3_ready - must not execute the stub when the tools are absent"
guard_dir="$work/guard"
mkdir -p "$guard_dir"
# Records that it ran, using only shell builtins: the fixture PATH holds this
# shim and nothing else, so an external `touch` would silently never fire and
# both directions of the control below would read "absent".
cat >"$guard_dir/python3" <<EOF
#!/bin/sh
: > "$work/python3-was-run"
echo 3
EOF
chmod +x "$guard_dir/python3"

rm -f "$work/python3-was-run"
answer=$(TEST_PATH="$guard_dir" run \
  'is_clt_stub() { return 0; }; clt_installed() { return 1; }
   if python3_ready; then echo true; else echo false; fi')
check "reports not-ready when it looks like the stub and CLT is absent" "false" "$answer"
check "and did NOT run the interpreter" "absent" \
  "$([ -e "$work/python3-was-run" ] && echo present || echo absent)"

rm -f "$work/python3-was-run"
answer=$(TEST_PATH="$guard_dir" run \
  'is_clt_stub() { return 1; }; clt_installed() { return 1; }
   if python3_ready; then echo true; else echo false; fi')
check "CONTROL: a non-stub python3 IS accepted" "true" "$answer"
check "CONTROL: and it WAS run" "present" \
  "$([ -e "$work/python3-was-run" ] && echo present || echo absent)"

# --- python3_ready / git_ready ----------------------------------------------
echo
echo "python3_ready / git_ready - the version is checked, not the command"
py3_dir="$work/py3"
shim "$py3_dir/python3" 3
py2_dir="$work/py2"
shim "$py2_dir/python3" 2
empty_dir="$work/empty"
mkdir -p "$empty_dir"
git_dir="$work/git"
shim "$git_dir/git" "git version 2.0.0"

check "a python3 reporting major 3 is ready" "true" \
  "$(TEST_PATH="$py3_dir" boolean python3_ready)"
check "a python3 reporting major 2 is NOT ready" "false" \
  "$(TEST_PATH="$py2_dir" boolean python3_ready)"
check "CONTROL: no python3 on PATH at all is NOT ready" "false" \
  "$(TEST_PATH="$empty_dir" boolean python3_ready)"
check "a working git is ready" "true" "$(TEST_PATH="$git_dir" boolean git_ready)"
check "CONTROL: no git on PATH at all is NOT ready" "false" \
  "$(TEST_PATH="$empty_dir" boolean git_ready)"

# --- missing_tools ----------------------------------------------------------
echo
echo "missing_tools - names what is actually broken"
check "python3 only" "python3" \
  "$(run 'python3_ready() { return 1; }; git_ready() { return 0; }; missing_tools')"
check "git only" "git" \
  "$(run 'python3_ready() { return 0; }; git_ready() { return 1; }; missing_tools')"
check "both" "python3 and git" \
  "$(run 'python3_ready() { return 1; }; git_ready() { return 1; }; missing_tools')"

# --- profile_for_shell ------------------------------------------------------
echo
echo "profile_for_shell - the file the login shell actually reads"
h_zsh="$work/h-zsh"
mkdir -p "$h_zsh"
check "zsh uses .zshrc" "$h_zsh/.zshrc" \
  "$(TEST_HOME="$h_zsh" TEST_SHELL=/bin/zsh run 'profile_for_shell')"

h_bp="$work/h-bp"
mkdir -p "$h_bp"
touch "$h_bp/.bash_profile" "$h_bp/.profile"
check "bash prefers an existing .bash_profile" "$h_bp/.bash_profile" \
  "$(TEST_HOME="$h_bp" TEST_SHELL=/bin/bash run 'profile_for_shell')"

# Creating .bash_profile here would stop bash reading .profile at all.
h_p="$work/h-p"
mkdir -p "$h_p"
touch "$h_p/.profile"
check "bash uses .profile rather than shadowing it" "$h_p/.profile" \
  "$(TEST_HOME="$h_p" TEST_SHELL=/bin/bash run 'profile_for_shell')"

h_none="$work/h-none"
mkdir -p "$h_none"
check "bash with neither falls back to .bash_profile" "$h_none/.bash_profile" \
  "$(TEST_HOME="$h_none" TEST_SHELL=/bin/bash run 'profile_for_shell')"

check "fish uses config.fish" "$h_none/.config/fish/config.fish" \
  "$(TEST_HOME="$h_none" TEST_SHELL=/usr/local/bin/fish run 'profile_for_shell')"

check "an unknown shell is declined" "declined" \
  "$(TEST_SHELL=/bin/ksh run 'if profile_for_shell >/dev/null; then echo chose; else echo declined; fi')"

# --- profile_line -----------------------------------------------------------
echo
echo "profile_line - portable, and \$PATH stays literal"
check "a path under HOME is written as \$HOME" 'export PATH="$HOME/.local/bin:$PATH"' \
  "$(TEST_HOME="$h_none" run 'BIN_DIR="$HOME/.local/bin"; profile_line')"
check "a path outside HOME is written whole" 'export PATH="/opt/dough/bin:$PATH"' \
  "$(TEST_HOME="$h_none" run 'BIN_DIR=/opt/dough/bin; profile_line')"
check "fish gets fish_add_path" 'fish_add_path "$HOME/.local/bin"' \
  "$(TEST_HOME="$h_none" TEST_SHELL=/usr/local/bin/fish run 'BIN_DIR="$HOME/.local/bin"; profile_line')"

# --- registered_dispatcher --------------------------------------------------
echo
echo "registered_dispatcher - reads back what the CLI wrote"
# Writes a settings.json whose PreToolUse hook is byte-for-byte the shape the
# CLI writes: the dispatcher path embedded in a python -c program as p=r'...'.
write_settings() { # write_settings <home> <dispatcher-path>
  local cmd
  cmd="python3 -c \\\"import os,runpy;p=r'$2';os.path.exists(p) and runpy.run_path(p,run_name='__main__')\\\" pre"
  mkdir -p "$1/.claude"
  printf '{\n  "model": "opus",\n  "hooks": {\n    "PreToolUse": [\n      { "matcher": ".*", "hooks": [ { "type": "command", "command": "%s" } ] }\n    ]\n  }\n}\n' \
    "$cmd" >"$1/.claude/settings.json"
}

h_ok="$work/h-ok"
write_settings "$h_ok" "/Users/someone/Dough/.dough/dough_trace.py"
check "extracts the dispatcher path" "/Users/someone/Dough/.dough/dough_trace.py" \
  "$(TEST_HOME="$h_ok" run 'registered_dispatcher')"

h_missing="$work/h-missing"
mkdir -p "$h_missing"
check "no settings.json at all is a failure" "none" \
  "$(TEST_HOME="$h_missing" run 'if registered_dispatcher >/dev/null; then echo found; else echo none; fi')"

h_other="$work/h-other"
write_settings "$h_other" "/Users/someone/other/thing.py"
check "CONTROL: another tool's python hook is not mistaken for ours" "none" \
  "$(TEST_HOME="$h_other" run 'if registered_dispatcher >/dev/null; then echo found; else echo none; fi')"

h_nohooks="$work/h-nohooks"
mkdir -p "$h_nohooks/.claude"
echo '{"model":"opus"}' >"$h_nohooks/.claude/settings.json"
check "settings.json with no hooks is a failure" "none" \
  "$(TEST_HOME="$h_nohooks" run 'if registered_dispatcher >/dev/null; then echo found; else echo none; fi')"

# --- ensure_on_path ---------------------------------------------------------
echo
echo "ensure_on_path - edits the profile once, and only when needed"
h_path="$work/h-path"
mkdir -p "$h_path"
printf 'alias ll="ls -l"\n' >"$h_path/.zshrc"
before=$(cat "$h_path/.zshrc")

TEST_HOME="$h_path" run 'BIN_DIR="$HOME/.local/bin"; ensure_on_path' >/dev/null
check "appends the export line" "1" \
  "$(grep -cxF 'export PATH="$HOME/.local/bin:$PATH"' "$h_path/.zshrc")"
check "keeps what was already there" "1" "$(grep -cxF 'alias ll="ls -l"' "$h_path/.zshrc")"

TEST_HOME="$h_path" run 'BIN_DIR="$HOME/.local/bin"; ensure_on_path' >/dev/null
check "is idempotent on a second run" "1" \
  "$(grep -cxF 'export PATH="$HOME/.local/bin:$PATH"' "$h_path/.zshrc")"

h_already="$work/h-already"
mkdir -p "$h_already/.local/bin"
printf 'alias ll="ls -l"\n' >"$h_already/.zshrc"
TEST_HOME="$h_already" TEST_PATH="/usr/bin:/bin:$h_already/.local/bin" run \
  'BIN_DIR="$HOME/.local/bin"; ensure_on_path' >/dev/null
check "writes nothing when the dir is already on PATH" "$before" "$(cat "$h_already/.zshrc")"

h_skip="$work/h-skip"
mkdir -p "$h_skip"
printf 'alias ll="ls -l"\n' >"$h_skip/.zshrc"
TEST_HOME="$h_skip" run \
  'BIN_DIR="$HOME/.local/bin"; ensure_on_path' DOUGH_SKIP_PROFILE=1 >/dev/null
check "DOUGH_SKIP_PROFILE=1 leaves the profile alone" "$before" "$(cat "$h_skip/.zshrc")"

h_unknown="$work/h-unknown"
mkdir -p "$h_unknown"
TEST_HOME="$h_unknown" TEST_SHELL=/bin/ksh run \
  'BIN_DIR="$HOME/.local/bin"; ensure_on_path' >/dev/null
check "an unknown shell has no profile written for it" "0" \
  "$(find "$h_unknown" -type f | wc -l | tr -d ' ')"

# --- resolve_bin_dir --------------------------------------------------------
echo
echo "resolve_bin_dir - an explicit DOUGH_BIN_DIR is honoured or refused"
writable="$work/writable"
mkdir -p "$writable"
check "a writable DOUGH_BIN_DIR is used" "$writable" \
  "$(run 'resolve_bin_dir; printf "%s\n" "$BIN_DIR"' "DOUGH_BIN_DIR=$writable")"

readonly_dir="$work/readonly"
mkdir -p "$readonly_dir"
chmod 555 "$readonly_dir"
check "an unwritable DOUGH_BIN_DIR stops the install" "1" \
  "$(status 'resolve_bin_dir' "DOUGH_BIN_DIR=$readonly_dir")"
check "CONTROL: a writable one does not stop it" "0" \
  "$(status 'resolve_bin_dir' "DOUGH_BIN_DIR=$writable")"
# Matched with `case`, not `grep -q`: under `set -o pipefail` grep closes the
# pipe on its first match, the writer dies of SIGPIPE, and a matching pipeline
# reports failure.
message="$(stderr 'resolve_bin_dir' "DOUGH_BIN_DIR=$readonly_dir")"
case "$message" in
  *"not writable"*) named="named" ;;
  *) named="silent" ;;
esac
check "and it says why rather than falling back silently" "named" "$named"
chmod 755 "$readonly_dir"

# --- failure paths ----------------------------------------------------------
# Every one of these is a branch a client can land on and nobody has ever seen
# render. An unset variable under `set -u`, a broken quote or a stale variable
# name would only show up here - as a crash instead of the message. Asserting
# "Setup stopped." AND a distinctive phrase is what tells those two apart.
echo
echo "failure paths - the error a client would actually see"

renders() { # renders <phrase> <snippet> [VAR=VALUE ...]
  local phrase="$1"
  shift
  local out
  out="$(stderr "$@")"
  case "$out" in
    *"Setup stopped."*"$phrase"*) echo "rendered" ;;
    *) echo "NOT RENDERED <<$out>>" ;;
  esac
}

# A stand-in `dough`. $1 picks how it misbehaves.
fake_dough() { # fake_dough <path> <mode>
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<EOF
#!/bin/sh
case "\$1:$2" in
  plugin:plugin-fails) exit 1 ;;
  status:*) echo '{"loggedIn":false}' ;;
  login:login-fails) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$1"
}

fakes="$work/fakes"
mkdir -p "$fakes"

printf '#!/bin/sh\necho Linux\n' >"$fakes/uname"
chmod +x "$fakes/uname"
check "a non-macOS host is turned away" "rendered" \
  "$(TEST_PATH="$fakes:/usr/bin:/bin" renders "supports macOS only" 'main')"

check "CLT present but python3 broken names python3" "rendered" \
  "$(renders "but python3 is still not usable" \
    'clt_installed() { return 0; }; python3_ready() { return 1; }; git_ready() { return 0; }
     ensure_prerequisites')"

check "waiting for the CLT eventually gives up" "rendered" \
  "$(renders "did not finish within 0s" \
    'python3_ready() { return 1; }; git_ready() { return 1; }; wait_for_clt' \
    "DOUGH_CLT_WAIT_SECONDS=0")"

curl_fail="$work/curl-fail"
mkdir -p "$curl_fail"
printf '#!/bin/sh\nexit 22\n' >"$curl_fail/curl"
chmod +x "$curl_fail/curl"
check "a failed download is reported as one" "rendered" \
  "$(TEST_PATH="$curl_fail:/usr/bin:/bin" renders "Could not download" 'install_cli' \
    "DOUGH_BIN_DIR=$writable")"

# Exits 0 and writes nothing, so the staged file stays zero bytes. Executing an
# empty file SUCCEEDS, so this is exactly the case a bare exit-status smoke
# check would wave through.
curl_empty="$work/curl-empty"
mkdir -p "$curl_empty"
printf '#!/bin/sh\nexit 0\n' >"$curl_empty/curl"
chmod +x "$curl_empty/curl"
check "an empty download is caught before it replaces anything" "rendered" \
  "$(TEST_PATH="$curl_empty:/usr/bin:/bin" renders "did not run" 'install_cli' \
    "DOUGH_BIN_DIR=$writable")"
check "CONTROL: and nothing was installed" "0" \
  "$(find "$writable" -type f | wc -l | tr -d ' ')"

fake_dough "$work/dough-noop" noop
h_nohook="$work/h-nohook"
mkdir -p "$h_nohook"
check "unregistered hooks are reported" "rendered" \
  "$(TEST_HOME="$h_nohook" renders "were not registered" \
    "DOUGH_BIN=$work/dough-noop; install_hooks")"

h_dangling="$work/h-dangling"
write_settings "$h_dangling" "$work/nowhere/dough_trace.py"
check "hooks pointing at missing files are reported" "rendered" \
  "$(TEST_HOME="$h_dangling" renders "not on disk" \
    "DOUGH_BIN=$work/dough-noop; install_hooks")"

fake_dough "$work/dough-plugin-fails" plugin-fails
check "a failed plugin install is reported" "rendered" \
  "$(renders "plugin install' failed" "DOUGH_BIN=$work/dough-plugin-fails; install_plugin")"

fake_dough "$work/dough-login-fails" login-fails
check "a failed login is reported" "rendered" \
  "$(renders "login' did not complete" "DOUGH_BIN=$work/dough-login-fails; sign_in")"
check "CONTROL: DOUGH_SKIP_LOGIN=1 does not even try" "0" \
  "$(status "DOUGH_BIN=$work/dough-login-fails; sign_in" DOUGH_SKIP_LOGIN=1)"

echo
if [ "$fail" -eq 0 ]; then
  printf '%d passed, 0 failed\n\n' "$pass"
  exit 0
fi
printf '%d passed, %d FAILED\n\n' "$pass" "$fail"
exit 1

#!/bin/sh
# Dough setup for macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/Dough-AI/dough-installer/main/install.sh | sh
#
# This is the whole setup, not just the binary: it makes sure the things Claude
# Code needs are there (python3 and git), installs the CLI, registers the Claude
# Code hooks and plugin, and signs you in. Every step checks before it acts, so
# re-running is also how you update.
#
# Env overrides:
#   DOUGH_BIN_DIR           install dir (default: /usr/local/bin, fallback ~/.local/bin)
#   DOUGH_REPO              release repo (default: Dough-AI/dough-installer)
#   DOUGH_SKIP_LOGIN        set to 1 to leave `dough login` to the user
#   DOUGH_SKIP_PROFILE      set to 1 to never edit a shell profile
#   DOUGH_CLT_WAIT_SECONDS  how long to wait for the Command Line Tools (default: 1200)
#
# Everything below lives inside main(), invoked on the very last line. Under
# `curl | sh` the shell reads this file from a pipe as it goes, so a truncated
# download must not run half a setup: it cannot call main() until it has read
# all of it.
set -eu

INSTALLER_URL="https://raw.githubusercontent.com/Dough-AI/dough-installer/main/install.sh"
INSTALL_CMD="curl -fsSL $INSTALLER_URL | sh"
REPO="${DOUGH_REPO:-Dough-AI/dough-installer}"
CLT_WAIT_SECONDS="${DOUGH_CLT_WAIT_SECONDS:-1200}"
PROFILE_MARKER="# Added by the Dough installer"

# Set as we go, read by the closing summary.
BIN_DIR=""
DOUGH_BIN=""
TMP_DOWNLOAD=""
NEW_TERMINAL_NEEDED=0

# --- output ----------------------------------------------------------------
# Human-facing output goes to stderr, so stdout stays clean for anything piping
# this. stderr is still the terminal under `curl | sh` - only stdin is the pipe -
# so colours work.
if [ -t 2 ]; then
  C_RESET=$(printf '\033[0m')
  C_RED=$(printf '\033[31m')
  C_GREEN=$(printf '\033[32m')
  C_YELLOW=$(printf '\033[33m')
  C_CYAN=$(printf '\033[36m')
  CURL_PROGRESS="--progress-bar"
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
  CURL_PROGRESS="--silent"
fi

step() { printf '\n%s==> %s%s\n' "$C_CYAN" "$1" "$C_RESET" >&2; }
good() { printf '    %s%s%s\n' "$C_GREEN" "$1" "$C_RESET" >&2; }
note() { printf '    %s\n' "$1" >&2; }

# fail <headline> [detail ...] - each argument is printed on its own line, so an
# empty argument is a deliberate blank separator and a multi-line argument keeps
# its newlines.
fail() {
  printf '\n%sSetup stopped.%s\n\n' "$C_RED" "$C_RESET" >&2
  for fail_line in "$@"; do
    printf '%s%s%s\n' "$C_YELLOW" "$fail_line" "$C_RESET" >&2
  done
  printf '\n' >&2
  exit 1
}

cleanup() {
  if [ -n "$TMP_DOWNLOAD" ]; then
    rm -f "$TMP_DOWNLOAD"
  fi
  return 0
}

# --- prerequisites ---------------------------------------------------------
# python3 and git are needed by Claude Code, not by the CLI - the binary is
# self-contained. `dough self-heal` registers hooks whose command is literally
# `python3 ...` (pythonExe() returns "python3" off Windows), and Claude Code
# itself wants git.
#
# On macOS both come from ONE thing, Apple's Command Line Tools, and until those
# are installed /usr/bin/python3 and /usr/bin/git are the same small stub that
# pops Apple's installer dialog when you run it. So `command -v python3`
# succeeding proves nothing, and *executing* it is not free of side effects:
# never run a /usr/bin tool without confirming the tools are actually installed.

clt_installed() {
  clt_dir=$(xcode-select -p 2>/dev/null) || return 1
  [ -n "$clt_dir" ] && [ -d "$clt_dir" ]
}

# The stub only ever lives in /usr/bin. A python3 or git from Homebrew, pyenv,
# conda or python.org is somewhere else and is safe to probe by running it.
is_clt_stub() {
  case "$1" in
    /usr/bin/*) return 0 ;;
    *) return 1 ;;
  esac
}

python3_ready() {
  py_path=$(command -v python3 2>/dev/null) || return 1
  if is_clt_stub "$py_path" && ! clt_installed; then
    return 1
  fi
  py_major=$(python3 -c 'import sys; print(sys.version_info.major)' 2>/dev/null) || return 1
  [ "$py_major" = "3" ]
}

git_ready() {
  git_path=$(command -v git 2>/dev/null) || return 1
  if is_clt_stub "$git_path" && ! clt_installed; then
    return 1
  fi
  git --version >/dev/null 2>&1
}

# Which of the two is unhappy, as a phrase for an error message.
missing_tools() {
  missing=""
  python3_ready || missing="python3"
  if ! git_ready; then
    if [ -n "$missing" ]; then
      missing="$missing and git"
    else
      missing="git"
    fi
  fi
  printf '%s\n' "$missing"
}

wait_for_clt() {
  waited=0
  interval=5
  while [ "$waited" -lt "$CLT_WAIT_SECONDS" ]; do
    if python3_ready && git_ready; then
      good "Command Line Tools installed."
      return 0
    fi
    sleep "$interval"
    waited=$((waited + interval))
    if [ $((waited % 60)) -eq 0 ]; then
      note "still waiting - ${waited}s elapsed. Ctrl-C is safe; re-running picks up where this left off."
    fi
  done
  fail \
    "The Command Line Tools did not finish within ${CLT_WAIT_SECONDS}s." \
    "" \
    "If the installer is still going, let it finish and then re-run:" \
    "  $INSTALL_CMD" \
    "" \
    "If no dialog ever appeared - over SSH, or on a managed Mac where an admin" \
    "has to approve it - install them from a console session first:" \
    "  xcode-select --install"
}

ensure_prerequisites() {
  step "Checking prerequisites"

  if python3_ready && git_ready; then
    good "python3 ($(command -v python3))"
    good "git ($(command -v git))"
    return 0
  fi

  if clt_installed; then
    # The tools are installed and something on PATH is still wrong, so
    # `xcode-select --install` has nothing to do. Say what is broken rather
    # than waiting out a download that will never start.
    fail \
      "The Command Line Tools are installed, but $(missing_tools) is still not usable." \
      "" \
      "Something earlier on your PATH is shadowing it. Check what it resolves to:" \
      "  command -v python3 && python3 --version" \
      "  command -v git && git --version" \
      "" \
      "Fix or remove that entry, open a new terminal, then re-run:" \
      "  $INSTALL_CMD"
  fi

  note "Claude Code needs python3 and git. On macOS both come from Apple's"
  note "Command Line Tools, and they are not installed yet."
  note ""
  note "A macOS dialog is about to open: choose Install and accept the licence."
  note "It is a large download, so this can take a while."
  # Errors if they are already installed or an install is already running.
  # Neither is a problem - the poll below is what decides.
  xcode-select --install >/dev/null 2>&1 || true
  wait_for_clt
}

# --- the binary ------------------------------------------------------------

resolve_bin_dir() {
  if [ -n "${DOUGH_BIN_DIR:-}" ]; then
    # Explicitly chosen: honour it or say why it cannot be used. Silently
    # installing somewhere else would be worse than stopping.
    if ! mkdir -p "$DOUGH_BIN_DIR" 2>/dev/null || [ ! -w "$DOUGH_BIN_DIR" ]; then
      fail \
        "DOUGH_BIN_DIR is set to $DOUGH_BIN_DIR, which is not writable." \
        "" \
        "Choose a directory you own, or unset it to use the default:" \
        "  DOUGH_BIN_DIR=\"\$HOME/.local/bin\" $INSTALL_CMD"
    fi
    BIN_DIR="$DOUGH_BIN_DIR"
    return 0
  fi

  # /usr/local/bin is already on the default PATH (see /etc/paths), but on a
  # stock Mac it is root-owned - so this normally lands in ~/.local/bin, and the
  # PATH step below is what makes that usable.
  BIN_DIR="/usr/local/bin"
  if ! mkdir -p "$BIN_DIR" 2>/dev/null || [ ! -w "$BIN_DIR" ]; then
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
  fi
}

install_cli() {
  step "Dough CLI"

  arch=$(uname -m)
  case "$arch" in
    arm64 | aarch64) arch="arm64" ;;
    x86_64 | amd64) arch="x64" ;;
    *) fail "Unsupported architecture: $arch" ;;
  esac

  asset="dough-darwin-${arch}"
  url="https://github.com/${REPO}/releases/latest/download/${asset}"

  resolve_bin_dir
  DOUGH_BIN="$BIN_DIR/dough"

  note "Downloading $asset..."
  TMP_DOWNLOAD=$(mktemp "${TMPDIR:-/tmp}/dough.XXXXXX")
  if ! curl -fSL "$CURL_PROGRESS" "$url" -o "$TMP_DOWNLOAD"; then
    fail \
      "Could not download $asset." \
      "" \
      "Check your network, then re-run:" \
      "  $INSTALL_CMD" \
      "" \
      "Or download it by hand from:" \
      "  https://github.com/${REPO}/releases/latest"
  fi
  # 755, not `+x`: mktemp creates the file 0600, so `+x` would leave it 0711 and
  # unreadable to anyone else in a shared /usr/local/bin.
  chmod 755 "$TMP_DOWNLOAD"

  # Prove the download runs BEFORE it replaces anything, or a truncated file
  # would surface later as a confusing hook or plugin failure instead.
  #
  # The version has to be non-empty, not merely a zero exit: executing a
  # ZERO-BYTE file succeeds, because the shell falls back to running it as an
  # empty script. An empty 200 response would otherwise pass this.
  version=$("$TMP_DOWNLOAD" --version 2>/dev/null) || version=""
  if [ -z "$version" ]; then
    fail \
      "The downloaded binary did not run." \
      "" \
      "The download may be corrupt or incomplete. Re-run:" \
      "  $INSTALL_CMD"
  fi

  mv "$TMP_DOWNLOAD" "$DOUGH_BIN"
  TMP_DOWNLOAD=""
  good "Installed $version to $DOUGH_BIN"
}

# --- PATH ------------------------------------------------------------------

# The startup file the user's login shell actually reads.
profile_for_shell() {
  case "$(basename "${SHELL:-/bin/zsh}")" in
    zsh)
      printf '%s\n' "$HOME/.zshrc"
      ;;
    bash)
      # macOS Terminal opens LOGIN shells, so .bash_profile is the file bash
      # reads - but creating one where only .profile exists would stop .profile
      # being read at all. Prefer whichever is already there.
      if [ -f "$HOME/.bash_profile" ]; then
        printf '%s\n' "$HOME/.bash_profile"
      elif [ -f "$HOME/.profile" ]; then
        printf '%s\n' "$HOME/.profile"
      else
        printf '%s\n' "$HOME/.bash_profile"
      fi
      ;;
    fish)
      printf '%s\n' "$HOME/.config/fish/config.fish"
      ;;
    *)
      return 1
      ;;
  esac
}

# The line to add, written with a literal $HOME so the profile stays portable.
profile_line() {
  line_dir="$BIN_DIR"
  case "$BIN_DIR" in
    "$HOME"/*) line_dir="\$HOME${BIN_DIR#"$HOME"}" ;;
  esac
  if [ "$(basename "${SHELL:-/bin/zsh}")" = "fish" ]; then
    printf 'fish_add_path "%s"\n' "$line_dir"
  else
    # $PATH must stay literal - it is expanded by the shell reading the profile,
    # not by us.
    # shellcheck disable=SC2016
    printf 'export PATH="%s:$PATH"\n' "$line_dir"
  fi
}

manual_path_hint() {
  note "Add this to your shell profile so new terminals can find dough:"
  note "  $(profile_line)"
}

ensure_on_path() {
  step "PATH"

  case ":$PATH:" in
    *":$BIN_DIR:"*)
      good "$BIN_DIR is already on your PATH."
      return 0
      ;;
  esac

  if [ "${DOUGH_SKIP_PROFILE:-}" = "1" ]; then
    note "DOUGH_SKIP_PROFILE=1 - not touching your shell profile."
    manual_path_hint
    NEW_TERMINAL_NEEDED=1
    return 0
  fi

  if ! profile=$(profile_for_shell); then
    note "Unrecognised shell (${SHELL:-unset}), so nothing was edited."
    manual_path_hint
    NEW_TERMINAL_NEEDED=1
    return 0
  fi

  line=$(profile_line)
  if [ -f "$profile" ] && grep -Fqx "$line" "$profile"; then
    good "$profile already puts $BIN_DIR on your PATH."
  else
    mkdir -p "$(dirname "$profile")"
    printf '\n%s\n%s\n' "$PROFILE_MARKER" "$line" >>"$profile"
    good "Added $BIN_DIR to your PATH in $profile"
  fi
  NEW_TERMINAL_NEEDED=1
}

# --- Claude Code hooks -----------------------------------------------------

# Reads the dispatcher path back out of the hook the CLI registered. Mirrors the
# CLI's own parse of the same command string, which embeds the path as p=r'...'.
registered_dispatcher() {
  settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || return 1
  dispatcher_path=$(grep -o "p=r'[^']*dough_trace\.py'" "$settings" |
    head -n 1 | sed "s/^p=r'//; s/'\$//")
  [ -n "$dispatcher_path" ] || return 1
  printf '%s\n' "$dispatcher_path"
}

install_hooks() {
  # `dough self-heal` writes ~/Dough/.dough/dough_trace.py + dough_secrets.py and
  # registers the Claude Code hooks that run them. Nothing else here does that -
  # `dough plugin install` does not.
  step "Claude Code hooks"

  # Keep whatever self-heal printed: it exits 0 unconditionally, so this output
  # is the only evidence of WHY it did nothing, and the checks below are the
  # only thing that notices it did.
  self_heal_output=$("$DOUGH_BIN" self-heal 2>&1) || true
  self_heal_detail=""
  if [ -n "$self_heal_output" ]; then
    self_heal_detail="
'dough self-heal' said:
  $self_heal_output"
  fi

  # self-heal catches every error internally and always exits 0, so its exit
  # code proves nothing. Assert the outcome instead: a hook registered in
  # settings.json, and the two files that hook needs actually on disk. The hook
  # is written to no-op silently when the dispatcher is missing, so an
  # unverified install would look healthy and capture nothing.
  if ! dispatcher=$(registered_dispatcher); then
    fail \
      "The Dough hooks were not registered in ~/.claude/settings.json." \
      "" \
      "If settings.json exists but is not valid JSON the CLI refuses to touch it;" \
      "fix or remove that file, then re-run:" \
      "  $INSTALL_CMD" \
      "$self_heal_detail"
  fi

  secrets_lib="$(dirname "$dispatcher")/dough_secrets.py"
  if [ ! -f "$dispatcher" ] || [ ! -f "$secrets_lib" ]; then
    fail \
      "The Dough hooks point at files that are not on disk." \
      "  $dispatcher" \
      "  $secrets_lib" \
      "" \
      "Re-run, and if it happens again report the output of:" \
      "  dough self-heal" \
      "" \
      "  $INSTALL_CMD" \
      "$self_heal_detail"
  fi

  good "Hooks registered against $dispatcher"
}

# --- Claude Code plugin ----------------------------------------------------

install_plugin() {
  # Needs no authentication: it fetches a public tarball over HTTPS, which is
  # why it can run before login.
  step "Claude Code plugin"
  if ! "$DOUGH_BIN" plugin install; then
    fail \
      "'dough plugin install' failed." \
      "" \
      "Run it on its own to see the full error:" \
      "  dough plugin install"
  fi
  good "Plugin installed."
}

# --- sign in ---------------------------------------------------------------

sign_in() {
  step "Sign in"

  if [ "${DOUGH_SKIP_LOGIN:-}" = "1" ]; then
    note "DOUGH_SKIP_LOGIN=1 - skipping. Run 'dough login' when you're ready."
    return 0
  fi

  # `dough status` prints JSON; loggedIn tells us whether to skip. Treat any
  # unreadable answer as "not logged in" and let login sort it out.
  if "$DOUGH_BIN" status 2>/dev/null | tr -d ' \t\n' | grep -q '"loggedIn":true'; then
    good "Already signed in."
    return 0
  fi

  note "Opening your browser to sign in..."
  if ! "$DOUGH_BIN" login; then
    fail \
      "'dough login' did not complete." \
      "" \
      "Run it again and finish the sign-in in your browser:" \
      "  dough login"
  fi
  good "Signed in."
}

# --- done ------------------------------------------------------------------

summarise() {
  printf '\n%sDough is set up.%s\n\n' "$C_GREEN" "$C_RESET" >&2
  printf '%sOne thing left, and it matters:%s\n' "$C_YELLOW" "$C_RESET" >&2
  printf '%s  Fully quit Claude Code and reopen it.%s\n' "$C_YELLOW" "$C_RESET" >&2
  printf '%s  Closing the window is not enough - use Cmd+Q, or right-click the Dock icon and Quit.%s\n' \
    "$C_YELLOW" "$C_RESET" >&2
  printf '  Claude Code reads the plugin and hooks at startup, so a running app sees none of this.\n' >&2
  if [ "$NEW_TERMINAL_NEEDED" = "1" ]; then
    printf '\n  Open a new terminal before using the dough command. This installer runs in\n' >&2
    printf '  its own shell and cannot change the PATH of the window you started it from.\n' >&2
  fi
  printf '\n' >&2
}

main() {
  trap cleanup EXIT

  os=$(uname -s)
  if [ "$os" != "Darwin" ]; then
    fail \
      "install.sh supports macOS only (Linux coming soon; Windows has its own installer)." \
      "  Detected: $os" \
      "" \
      "Windows:" \
      "  irm https://raw.githubusercontent.com/Dough-AI/dough-installer/main/install.ps1 | iex"
  fi

  ensure_prerequisites
  install_cli
  ensure_on_path
  install_hooks
  install_plugin
  sign_in
  summarise
}

main "$@"

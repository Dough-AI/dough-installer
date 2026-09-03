# Dough Installer

Public distribution for the **`dough`** CLI. Source lives in a private repo; this
repo holds only the installer script and the compiled, release binaries.

## Install (macOS)

```sh
curl -fsSL https://raw.githubusercontent.com/Dough-AI/dough-installer/main/install.sh | sh
```

This downloads the right binary for your Mac (Apple Silicon or Intel) and installs
it to `/usr/local/bin` (or `~/.local/bin` if that isn't writable).

## Install (Windows)

In PowerShell or Windows Terminal:

```powershell
irm https://raw.githubusercontent.com/Dough-AI/dough-installer/main/install.ps1 | iex
```

This is the whole setup, not just the binary. In order it:

1. checks `winget` is available;
2. installs **Python 3** if `python` isn't already a working interpreter — Claude Code
   runs the Dough hooks with it;
3. installs **Git** if missing — the Claude Code desktop app needs it;
4. downloads `dough.exe` to `%LOCALAPPDATA%\dough\bin`, adds it to your user PATH, and
   confirms it runs;
5. registers the Claude Code hooks and verifies they landed;
6. installs the Claude Code plugin;
7. signs you in (skipped if you already have a session).

It's safe to re-run: every step checks before it acts, so re-running is also how you
update the CLI and the plugin. It stops at the first thing it can't fix and tells you
what to do.

The binary is unsigned, so the first run may show a Windows SmartScreen prompt —
choose **More info → Run anyway**.

**After it finishes, fully quit Claude Code and reopen it.** Closing the window is not
enough — use Alt+F4 or quit from the system tray. Claude Code reads the plugin and
hooks at startup.

Environment overrides: `DOUGH_REPO` (release repo), `DOUGH_SKIP_LOGIN=1` (leave
`dough login` to the user).

## After installing

```sh
dough agent list
```

On macOS you still sign in separately:

```sh
dough login --url https://app.usedough.ai
```

## Tests

The Windows installer's helpers have unit tests. They need PowerShell 7 and run on any
platform (macOS included):

```sh
pwsh -NoProfile -File test/install.Tests.ps1
```

Lint and parse it too:

```sh
pwsh -NoProfile -Command 'Import-Module PSScriptAnalyzer; Invoke-ScriptAnalyzer -Path install.ps1 -ExcludeRule PSAvoidUsingWriteHost'
```

`PSAvoidUsingWriteHost` is excluded deliberately — this is an installer whose output is
for a human watching a terminal.

> Linux support is coming soon.

## What gets installed

A single self-contained binary. It contains no embedded secrets (verified at build
time) and requires `dough login` before it can do anything.

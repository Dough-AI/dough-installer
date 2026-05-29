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

In PowerShell:

```powershell
irm https://raw.githubusercontent.com/Dough-AI/dough-installer/main/install.ps1 | iex
```

This downloads `dough.exe` to `%LOCALAPPDATA%\dough\bin` and adds it to your user
PATH (open a new terminal afterward). The binary is unsigned, so the first run may
show a Windows SmartScreen prompt — choose **More info → Run anyway**.

## After installing

```sh
dough login --url https://app.usedough.ai
dough agent list
```

> Linux support is coming soon.

## What gets installed

A single self-contained binary. It contains no embedded secrets (verified at build
time) and requires `dough login` before it can do anything.

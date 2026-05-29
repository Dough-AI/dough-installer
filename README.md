# Dough Installer

Public distribution for the **`dough`** CLI. Source lives in a private repo; this
repo holds only the installer script and the compiled, release binaries.

## Install (macOS)

```sh
curl -fsSL https://raw.githubusercontent.com/Dough-AI/dough-installer/main/install.sh | sh
```

This downloads the right binary for your Mac (Apple Silicon or Intel) and installs
it to `/usr/local/bin` (or `~/.local/bin` if that isn't writable).

Then authenticate:

```sh
dough login --url https://app.usedough.ai
dough agent list
```

> Windows and Linux support are coming soon.

## What gets installed

A single self-contained binary. It contains no embedded secrets (verified at build
time) and requires `dough login` before it can do anything.

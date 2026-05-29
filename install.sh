#!/bin/sh
# Dough CLI installer.
#   curl -fsSL https://raw.githubusercontent.com/Dough-AI/dough-installer/main/install.sh | sh
#
# Env overrides:
#   DOUGH_BIN_DIR   target install dir (default: /usr/local/bin, fallback ~/.local/bin)
#   DOUGH_REPO      release repo (default: Dough-AI/dough-installer)
set -eu

REPO="${DOUGH_REPO:-Dough-AI/dough-installer}"

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Darwin) os="darwin" ;;
  *)
    echo "dough: install.sh currently supports macOS only (Windows/Linux coming soon)." >&2
    echo "       Detected: $os" >&2
    exit 1
    ;;
esac

case "$arch" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64)  arch="x64" ;;
  *)
    echo "dough: unsupported architecture: $arch" >&2
    exit 1
    ;;
esac

asset="dough-${os}-${arch}"
url="https://github.com/${REPO}/releases/latest/download/${asset}"

# Choose an install dir we can write to.
bindir="${DOUGH_BIN_DIR:-/usr/local/bin}"
if ! mkdir -p "$bindir" 2>/dev/null || [ ! -w "$bindir" ]; then
  bindir="$HOME/.local/bin"
  mkdir -p "$bindir"
fi

tmp="$(mktemp)"
echo "dough: downloading ${asset}..." >&2
curl -fSL "$url" -o "$tmp"
chmod +x "$tmp"
mv "$tmp" "$bindir/dough"
echo "dough: installed to $bindir/dough" >&2

# PATH hint if needed.
case ":$PATH:" in
  *":$bindir:"*) ;;
  *)
    echo "dough: $bindir is not on your PATH. Add this to your shell profile:" >&2
    echo "         export PATH=\"$bindir:\$PATH\"" >&2
    ;;
esac

echo "" >&2
echo "Next: dough login --url https://app.usedough.ai" >&2

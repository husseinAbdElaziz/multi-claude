#!/usr/bin/env bash
# mcc installer for macOS, Linux, and WSL.
#
#   curl -fsSL https://raw.githubusercontent.com/husseinAbdElaziz/multi-claude/main/install.sh | bash
#
# Environment overrides:
#   MCC_VERSION       version to install (e.g. 0.1.0); defaults to the latest release
#   MCC_INSTALL_DIR   directory to install into; defaults to /usr/local/bin or ~/.local/bin
set -euo pipefail

REPO="husseinAbdElaziz/multi-claude"
BINARY="mcc"
VERSION="${MCC_VERSION:-latest}"
INSTALL_DIR="${MCC_INSTALL_DIR:-}"

info() { printf '==> %s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- detect platform --------------------------------------------------------
os="$(uname -s)"
case "$os" in
  Darwin) os_name="macos" ;;
  Linux)  os_name="linux" ;;
  *) err "unsupported OS '$os'. mcc supports macOS and Linux; on Windows use WSL." ;;
esac

arch="$(uname -m)"
case "$arch" in
  arm64|aarch64) arch_name="arm64" ;;
  x86_64|amd64)  arch_name="x64" ;;
  *) err "unsupported architecture '$arch'." ;;
esac

asset="${BINARY}-${os_name}-${arch_name}.tar.gz"

# --- resolve download URL ---------------------------------------------------
if [ "$VERSION" = "latest" ]; then
  base="https://github.com/${REPO}/releases/latest/download"
  label="latest"
else
  v="${VERSION#v}"
  base="https://github.com/${REPO}/releases/download/v${v}"
  label="v${v}"
fi
url="${base}/${asset}"

# --- pick a downloader ------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO "$2" "$1"; }
else
  err "need either curl or wget installed."
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

info "Downloading ${asset} (${label})"
fetch "$url" "$tmp/$asset" || err "download failed: $url"

# --- verify checksum (best-effort) ------------------------------------------
if fetch "${base}/SHA256SUMS" "$tmp/SHA256SUMS" 2>/dev/null; then
  expected="$(awk -v f="$asset" '$2 == f {print $1}' "$tmp/SHA256SUMS")"
  if [ -n "$expected" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
    else
      actual=""
    fi
    if [ -n "$actual" ] && [ "$expected" != "$actual" ]; then
      err "checksum mismatch for ${asset} (expected ${expected}, got ${actual})"
    fi
    [ -n "$actual" ] && info "Checksum verified"
  fi
fi

# --- extract ----------------------------------------------------------------
tar -xzf "$tmp/$asset" -C "$tmp"
[ -f "$tmp/$BINARY" ] || err "archive did not contain '$BINARY'."
chmod +x "$tmp/$BINARY"

# --- choose install directory -----------------------------------------------
if [ -z "$INSTALL_DIR" ]; then
  if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    INSTALL_DIR="/usr/local/bin"
  elif [ "$(id -u)" = "0" ]; then
    INSTALL_DIR="/usr/local/bin"
  else
    INSTALL_DIR="$HOME/.local/bin"
  fi
fi
mkdir -p "$INSTALL_DIR" 2>/dev/null || true

# --- install ----------------------------------------------------------------
dest="$INSTALL_DIR/$BINARY"
if mv "$tmp/$BINARY" "$dest" 2>/dev/null; then
  :
elif command -v sudo >/dev/null 2>&1; then
  info "Writing to $INSTALL_DIR requires elevated permissions"
  sudo mkdir -p "$INSTALL_DIR"
  sudo mv "$tmp/$BINARY" "$dest"
else
  err "cannot write to $INSTALL_DIR. Re-run with MCC_INSTALL_DIR set to a writable path."
fi

info "Installed $BINARY to $dest"

# --- PATH hint --------------------------------------------------------------
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    printf '\n'
    info "$INSTALL_DIR is not on your PATH. Add this to your shell profile:"
    printf '    export PATH="%s:$PATH"\n' "$INSTALL_DIR"
    ;;
esac

"$dest" --version 2>/dev/null || true

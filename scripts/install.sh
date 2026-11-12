#!/usr/bin/env bash
# Builds CLIsland from source and installs it to ~/.local/bin (or $CLISLAND_PREFIX/bin).
set -euo pipefail

REPO="${CLISLAND_REPO:-https://github.com/nevinchanyi/clisland.git}"
REF="${CLISLAND_REF:-main}"
PREFIX="${CLISLAND_PREFIX:-$HOME/.local}"

if [[ "$(uname)" != "Darwin" ]]; then echo "CLIsland runs on macOS only." >&2; exit 1; fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Swift not found. Install the Command Line Tools: xcode-select --install" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "==> Downloading CLIsland ($REF)"
git clone --quiet --depth 1 --branch "$REF" "$REPO" "$work/clisland"
echo "==> Building (about a minute)"
(cd "$work/clisland" && swift build -c release --disable-sandbox >/dev/null)
bin="$(cd "$work/clisland" && swift build -c release --show-bin-path)/clisland"
mkdir -p "$PREFIX/bin"
install -m 0755 "$bin" "$PREFIX/bin/clisland"
echo "==> Installed $PREFIX/bin/clisland"

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "Add $PREFIX/bin to your PATH, e.g.: echo 'export PATH=\"$PREFIX/bin:\$PATH\"' >> ~/.zshrc" ;;
esac

if [[ "${CLISLAND_NO_SETUP:-}" != "1" ]]; then
  CLISLAND_BIN="$PREFIX/bin/clisland" "$PREFIX/bin/clisland" setup
fi

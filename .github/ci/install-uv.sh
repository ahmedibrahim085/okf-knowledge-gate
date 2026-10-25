#!/usr/bin/env bash
# Installs uv <version> in ~/.local/bin from its GitHub release tarball, only when the tarball's sha256 is the one pinned in
# uv-sha256.txt next to this script. It replaces `curl .../install.sh | sh`, which ran a downloaded script that nothing
# checked (BL-881). Usage: install-uv.sh <version>
set -euo pipefail
v=${1:?usage: install-uv.sh <uv version>}
case "$(uname -m)" in
  x86_64|amd64) target=x86_64-unknown-linux-gnu ;;
  aarch64|arm64) target=aarch64-unknown-linux-gnu ;;
  *) echo "install-uv: no uv build is pinned for $(uname -m)" >&2; exit 2 ;;
esac
sums="$(dirname "$0")/uv-sha256.txt"
want=$(awk -v v="$v" -v t="$target" '$1==v && $2==t {print $3}' "$sums" | sort -u)   # identical duplicate pins are one pin
[ -n "$want" ] || { echo "install-uv: no pinned sha256 for uv $v ($target) in $sums" >&2; exit 2; }
case "$want" in *$'\n'*) echo "install-uv: two different pins for uv $v ($target) in $sums: keep one" >&2; exit 2 ;; esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/uv.tar.gz" "https://github.com/astral-sh/uv/releases/download/$v/uv-$target.tar.gz"
# sha256sum on the Linux runners; shasum on macOS, where tools/ci-workflow.test.sh runs this script too.
if command -v sha256sum >/dev/null; then got=$(sha256sum "$tmp/uv.tar.gz"); else got=$(shasum -a 256 "$tmp/uv.tar.gz"); fi
got=${got%% *}
[ "$got" = "$want" ] || { echo "install-uv: sha256 of uv $v ($target) is $got, the pinned one is $want: not installed" >&2; exit 1; }
tar -xzf "$tmp/uv.tar.gz" -C "$tmp"
mkdir -p "$HOME/.local/bin"
cp "$tmp/uv-$target/uv" "$tmp/uv-$target/uvx" "$HOME/.local/bin/"

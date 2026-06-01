#!/usr/bin/env bash
# Push the freshly generated Formula/mcc.rb to the Homebrew tap repo.
#
# Required env:
#   TAP_TOKEN  - a GitHub PAT (or fine-grained token) with write access to the tap repo
#   TAG        - the release tag (e.g. v0.1.0)
# Optional env:
#   TAP_REPO   - owner/name of the tap repo (default: husseinAbdElaziz/homebrew-tap)
set -euo pipefail

: "${TAP_TOKEN:?TAP_TOKEN (HOMEBREW_TAP_TOKEN) is required}"
TAP_REPO="${TAP_REPO:-husseinAbdElaziz/homebrew-tap}"
VERSION="${TAG:-}"
VERSION="${VERSION#v}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git clone --depth 1 "https://x-access-token:${TAP_TOKEN}@github.com/${TAP_REPO}.git" "$tmp/tap"

mkdir -p "$tmp/tap/Formula"
cp Formula/mcc.rb "$tmp/tap/Formula/mcc.rb"

cd "$tmp/tap"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Formula/mcc.rb

if git diff --cached --quiet; then
  echo "Formula already up to date; nothing to publish."
  exit 0
fi

git commit -m "mcc ${VERSION:-release}"
git push
echo "Published mcc ${VERSION} to ${TAP_REPO}."

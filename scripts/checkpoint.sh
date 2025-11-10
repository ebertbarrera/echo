#!/usr/bin/env bash
set -euo pipefail
msg="${1:-checkpoint}"
git add -A
if ! git diff --cached --quiet; then
  git commit -m "$msg"
  git push -u origin HEAD || true
fi

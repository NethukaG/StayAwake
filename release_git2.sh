#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
git add -A
git commit -F commitmsg3.txt
git tag -f v1.12.3 HEAD
git push origin main
git push -f origin v1.12.3
echo DONE_PUSH

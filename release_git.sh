#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
git add -A
git commit -F commitmsg2.txt
rm -f commitmsg2.txt
git add -A
git commit --amend --no-edit
git tag -f v1.12.2 HEAD
git push origin main
git push -f origin v1.12.2
echo DONE_PUSH

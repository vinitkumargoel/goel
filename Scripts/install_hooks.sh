#!/bin/bash
# Point git at the repo's versioned hooks (Scripts/git-hooks). Run once per clone.
# Undo with: git config --unset core.hooksPath
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

chmod +x Scripts/git-hooks/*
git config core.hooksPath Scripts/git-hooks

echo "Hooks installed — core.hooksPath = $(git config core.hooksPath)"
echo "Active:"
for h in Scripts/git-hooks/*; do
    [ -f "$h" ] && echo "  $(basename "$h")"
done

#!/bin/bash
# Builds Excalidraw's editor for boards (board/) into build/board, which the app bundles.
set -euo pipefail
cd "$(dirname "$0")/../board"
[ -d node_modules ] || npm ci
npm run build --silent

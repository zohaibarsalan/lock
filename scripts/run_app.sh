#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Lock.app"

cd "$ROOT_DIR"
./scripts/build_app.sh
open -na "$APP_DIR"

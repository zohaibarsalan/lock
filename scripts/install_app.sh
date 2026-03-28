#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/dist/Lock.app"
TARGET_APP="/Applications/Lock.app"

cd "$ROOT_DIR"
./scripts/build_app.sh

rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"

echo "Installed app at: $TARGET_APP"

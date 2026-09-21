#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MODE="${1:-run}"
case "$MODE" in run|--build-only|--verify|--debug|--logs|--telemetry) ;; *) echo "Usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
APP_NAME='X Media Assist'
APP_BUNDLE="$ROOT_DIR/build/DerivedData/Build/Products/Debug/$APP_NAME.app"
if [[ "$MODE" != --build-only ]]; then pkill -x "$APP_NAME" >/dev/null 2>&1 || true; fi
# Use the Team and signing settings configured for both targets in Xcode.
xcodebuild -quiet -project 'X Media Assist/X Media Assist.xcodeproj' -scheme 'X Media Assist' -configuration Debug -derivedDataPath build/DerivedData build
if [[ "$MODE" == --build-only ]]; then exit 0; fi
if [[ "$MODE" == --debug ]]; then exec lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"; fi
open "$APP_BUNDLE"
case "$MODE" in
 --verify) sleep 2; pgrep -x "$APP_NAME" >/dev/null ;;
 --logs|--telemetry) /usr/bin/log stream --info --style compact --predicate 'process == "X Media Assist" OR process == "X Media Assist Extension"' ;;
esac

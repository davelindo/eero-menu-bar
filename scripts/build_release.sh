#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DERIVED_DIR="${BUILD_DIR}/DerivedData"
APP_PATH="${DERIVED_DIR}/Build/Products/Release/EeroControl.app"
OUT_APP="${BUILD_DIR}/EeroControl.app"

mkdir -p "${BUILD_DIR}"

xcodegen generate --spec "${ROOT_DIR}/project.yml" --project "${ROOT_DIR}"

xcodebuild \
  -project "${ROOT_DIR}/EeroControl.xcodeproj" \
  -scheme EeroControl \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "${DERIVED_DIR}" \
  build

rm -rf "${OUT_APP}"
cp -R "${APP_PATH}" "${OUT_APP}"

echo "Release app: ${OUT_APP}"

#!/usr/bin/env bash
# Build local_backupnotice install zip (Moodle-compatible).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
    exec python3 "${ROOT}/build-zip.py"
fi

if command -v python >/dev/null 2>&1; then
    exec python "${ROOT}/build-zip.py"
fi

SRC="${ROOT}/local/backupnotice"
DIST="${ROOT}/dist"
VERSION="$(grep -E '\$plugin->version\s*=' "${SRC}/version.php" | grep -oE '[0-9]+' | head -1)"
ZIP_PATH="${DIST}/local_backupnotice_moodle40-${VERSION}.zip"

mkdir -p "${DIST}"
rm -f "${DIST}"/local_backupnotice_moodle40-*.zip

(
    cd "${ROOT}/local"
    zip -r "${ZIP_PATH}" backupnotice -x '*.git*' -x '*~'
)

echo "Created: ${ZIP_PATH}"

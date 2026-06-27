#!/usr/bin/env bash
# Invoke quiz_backup.php as the backup user (requires CLI bootstrap ACL in setup-moodledata-acl.sh).
# Used by GUI poll and manual CLI; moodle-backup.sh uses quiz.sh instead.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_BIN_DIR="$(cd "${LIB_DIR}/.." && pwd)"

# shellcheck source=common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=quiz.sh
source "${LIB_DIR}/quiz.sh"

load_env "${REMOTE_BIN_DIR}/moodle-backup.env"

if [[ $# -lt 2 ]]; then
    echo "Usage: run_quiz_php.sh MOODLE_ROOT command [args...]" >&2
    echo "Example: run_quiz_php.sh /var/www/moodle list" >&2
    exit 1
fi

MOODLE_ROOT="$(sanitize_env_value "$1")"
shift

if [[ ! -d "${MOODLE_ROOT}" ]]; then
    echo "ERROR: Moodle root not found: ${MOODLE_ROOT}" >&2
    exit "${EXIT_CONFIG}"
fi

quiz_php "$@"

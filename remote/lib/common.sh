#!/usr/bin/env bash
# Shared utilities for Moodle backup scripts.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_BIN_DIR="$(cd "${LIB_DIR}/.." && pwd)"

# Exit codes
readonly EXIT_OK=0
readonly EXIT_CONFIG=1
readonly EXIT_MAINTENANCE=2
readonly EXIT_DATABASE=3
readonly EXIT_ARCHIVE=4
readonly EXIT_CANCELLED=5
readonly EXIT_QUIZ=6

BACKUP_FULL=false
BACKUP_SIMULATE=false
BACKUP_SIMULATE_SECONDS=5
BACKUP_FORCE=false
BACKUP_QUIZ_PREP=true
MOOBACKUP_QUIZ_PHP=""
MOODLE_ROOT=""
BACKUPER_STORAGE_PATH=""
BACKUP_DIR=""
LOG_FILE=""
ERROR_STEP=""
MAINTENANCE_ENABLED=false
BACKUP_START_EPOCH=""
MYSQL_DEFAULTS_FILE=""

sanitize_env_value() {
    local v="$1"
    v="${v//$'\r'/}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

load_env() {
    local env_file="${1:-${REMOTE_BIN_DIR}/moodle-backup.env}"
    if [[ -f "${env_file}" ]]; then
        # shellcheck disable=SC1090
        set -a
        source "${env_file}"
        set +a
    fi

    MOODLE_ROOT="$(sanitize_env_value "${MOODLE_ROOT:-${BACKUPER_LOCATION:-}}")"
    BACKUPER_STORAGE_PATH="$(sanitize_env_value "${BACKUPER_STORAGE_PATH:-}")"
    MOOBACKUP_QUIZ_PHP="$(sanitize_env_value "${MOOBACKUP_QUIZ_PHP:-}")"

    if [[ -z "${MOODLE_ROOT}" || -z "${BACKUPER_STORAGE_PATH}" ]]; then
        echo "ERROR: MOODLE_ROOT/BACKUPER_LOCATION and BACKUPER_STORAGE_PATH must be set." >&2
        exit "${EXIT_CONFIG}"
    fi

    if [[ ! -d "${MOODLE_ROOT}" ]]; then
        echo "ERROR: Moodle root not found: ${MOODLE_ROOT}" >&2
        exit "${EXIT_CONFIG}"
    fi

    if [[ ! -f "${MOODLE_ROOT}/config.php" ]]; then
        echo "ERROR: config.php not found in ${MOODLE_ROOT}" >&2
        exit "${EXIT_CONFIG}"
    fi
}

parse_backup_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full)
                BACKUP_FULL=true
                shift
                ;;
            --simulate)
                BACKUP_SIMULATE=true
                shift
                ;;
            --simulate-seconds)
                BACKUP_SIMULATE_SECONDS="$2"
                shift 2
                ;;
            --force)
                BACKUP_FORCE=true
                shift
                ;;
            --no-quiz-prep)
                BACKUP_QUIZ_PREP=false
                shift
                ;;
            --storage)
                BACKUPER_STORAGE_PATH="$2"
                shift 2
                ;;
            --moodle-root)
                MOODLE_ROOT="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: moodle-backup.sh [--full] [--simulate] [--simulate-seconds N]"
                echo "       [--force] [--no-quiz-prep] [--storage PATH] [--moodle-root PATH]"
                exit "${EXIT_OK}"
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                exit "${EXIT_CONFIG}"
                ;;
        esac
    done

    if [[ ! "${BACKUP_SIMULATE_SECONDS}" =~ ^[0-9]+$ ]] || [[ "${BACKUP_SIMULATE_SECONDS}" -lt 1 ]]; then
        echo "ERROR: --simulate-seconds must be a positive integer (got: ${BACKUP_SIMULATE_SECONDS})" >&2
        exit "${EXIT_CONFIG}"
    fi
}

init_backup_dirs() {
    mkdir -p "${BACKUPER_STORAGE_PATH}"
    BACKUP_DIR="${BACKUPER_STORAGE_PATH}/$(date +%Y-%m-%d_%H-%M-%S)"
    mkdir -p "${BACKUP_DIR}"
    LOG_FILE="${BACKUP_DIR}/backup.log"
    BACKUP_START_EPOCH="$(date +%s)"
}

check_disk_space() {
    local target="${BACKUPER_STORAGE_PATH}"
    local avail_kb
    avail_kb="$(df -Pk "${target}" | awk 'NR==2 {print $4}')"
    if [[ -z "${avail_kb}" || "${avail_kb}" -lt 1048576 ]]; then
        log_warn "Less than 1 GB free on ${target} (${avail_kb:-unknown} KB available)"
    fi
}

require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        log_error "Required command not found: ${cmd}"
        exit "${EXIT_CONFIG}"
    fi
}

require_commands() {
    require_command php
    require_command tar
    require_command gzip
    require_command df
    if command -v mariadb-dump >/dev/null 2>&1; then
        :
    elif command -v mysqldump >/dev/null 2>&1; then
        :
    else
        log_error "Neither mariadb-dump nor mysqldump found"
        exit "${EXIT_CONFIG}"
    fi
}

dump_binary() {
    if command -v mariadb-dump >/dev/null 2>&1; then
        echo "mariadb-dump"
    else
        echo "mysqldump"
    fi
}

human_size() {
    local bytes="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "${bytes}" 2>/dev/null || echo "${bytes} bytes"
    else
        echo "${bytes} bytes"
    fi
}

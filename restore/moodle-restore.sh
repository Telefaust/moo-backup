#!/usr/bin/env bash
# Restore Moodle from a Moo-backup directory (multi-file archive).
# Runs as the current user — no implicit sudo.

set -euo pipefail

readonly EXIT_OK=0
readonly EXIT_CONFIG=1
readonly EXIT_PERMISSIONS=2
readonly EXIT_EXTRACT=3
readonly EXIT_DATABASE=4
readonly EXIT_RESTORE=5

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARCHIVE_PATH=""
WEBROOT=""
DATAROOT=""
DB_HOST=""
DB_NAME=""
DB_USER=""
DB_PASS=""
DB_CREATE=false
REPLACE_URL=""
REPLACE_WITH=""
SKIP_DB=false
DRY_RUN=false
WORK_DIR=""
LOG_FILE=""

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    [[ -n "${LOG_FILE}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE}"
}

log_info()  { log_msg "INFO: $*"; }
log_warn()  { log_msg "WARN: $*"; }
log_error() { log_msg "ERROR: $*" >&2; }

usage() {
    cat <<EOF
Usage: moodle-restore.sh --archive PATH [options]

Required:
  --archive PATH       Path to backup directory (manifest.json + component files)

Target paths (default: from manifest.json inside archive):
  --webroot PATH       Moodle code directory (dirroot)
  --dataroot PATH      Moodle data directory

Database:
  --db-host HOST
  --db-name NAME
  --db-user USER
  --db-pass PASS
  --db-create          Create database if missing (requires privileges)

URL replacement (optional):
  --replace-url OLD    Search URL in database
  --replace-with NEW   Replacement URL

Other:
  --skip-db            Restore files only, skip database import
  --dry-run            Validate permissions and show plan only
  -h, --help           Show this help
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --archive)     ARCHIVE_PATH="$2"; shift 2 ;;
            --webroot)     WEBROOT="$2"; shift 2 ;;
            --dataroot)    DATAROOT="$2"; shift 2 ;;
            --db-host)     DB_HOST="$2"; shift 2 ;;
            --db-name)     DB_NAME="$2"; shift 2 ;;
            --db-user)     DB_USER="$2"; shift 2 ;;
            --db-pass)     DB_PASS="$2"; shift 2 ;;
            --db-create)   DB_CREATE=true; shift ;;
            --replace-url) REPLACE_URL="$2"; shift 2 ;;
            --replace-with) REPLACE_WITH="$2"; shift 2 ;;
            --skip-db)     SKIP_DB=true; shift ;;
            --dry-run)     DRY_RUN=true; shift ;;
            -h|--help)     usage; exit "${EXIT_OK}" ;;
            *) log_error "Unknown option: $1"; usage; exit "${EXIT_CONFIG}" ;;
        esac
    done

    if [[ -z "${ARCHIVE_PATH}" ]]; then
        log_error "--archive is required"
        usage
        exit "${EXIT_CONFIG}"
    fi
}

resolve_archive() {
    if [[ ! -d "${ARCHIVE_PATH}" ]]; then
        log_error "Backup directory not found: ${ARCHIVE_PATH}"
        exit "${EXIT_CONFIG}"
    fi
    if [[ ! -f "${ARCHIVE_PATH}/manifest.json" ]] || [[ ! -f "${ARCHIVE_PATH}/database.sql.gz" ]]; then
        log_error "No valid backup in directory: ${ARCHIVE_PATH}"
        log_error "Expected manifest.json and database.sql.gz"
        exit "${EXIT_CONFIG}"
    fi
}

prepare_backup_files() {
    WORK_DIR="${ARCHIVE_PATH}"
    LOG_FILE="${WORK_DIR}/restore.log"
    log_info "Using backup directory: ${WORK_DIR}"
}

check_rw_access() {
    local path="$1"
    local label="$2"

    if [[ ! -e "${path}" ]]; then
        if ! mkdir -p "${path}" 2>/dev/null; then
            log_error "${label}: cannot create ${path} (no write permission)"
            exit "${EXIT_PERMISSIONS}"
        fi
    fi

    if [[ ! -r "${path}" ]]; then
        log_error "${label}: no read permission on ${path}"
        exit "${EXIT_PERMISSIONS}"
    fi

    if [[ ! -w "${path}" ]]; then
        log_error "${label}: no write permission on ${path}"
        exit "${EXIT_PERMISSIONS}"
    fi

    local probe="${path}/.moobackup_probe_$$"
    if ! touch "${probe}" 2>/dev/null; then
        log_error "${label}: cannot write probe file in ${path}"
        exit "${EXIT_PERMISSIONS}"
    fi
    rm -f "${probe}"
    log_info "${label}: read/write OK (${path})"
}

read_manifest() {
    local manifest="${WORK_DIR}/manifest.json"
    if [[ ! -f "${manifest}" ]]; then
        log_error "manifest.json not found in archive"
        exit "${EXIT_EXTRACT}"
    fi

    if [[ -z "${WEBROOT}" ]]; then
        WEBROOT="$(python3 -c "import json; print(json.load(open('${manifest}'))['dirroot'])" 2>/dev/null || \
                   php -r "echo json_decode(file_get_contents('${manifest}'))->dirroot;" 2>/dev/null || true)"
    fi
    if [[ -z "${DATAROOT}" ]]; then
        DATAROOT="$(python3 -c "import json; print(json.load(open('${manifest}'))['dataroot'])" 2>/dev/null || \
                    php -r "echo json_decode(file_get_contents('${manifest}'))->dataroot;" 2>/dev/null || true)"
    fi
    if [[ -z "${DB_HOST}" ]]; then
        DB_HOST="$(python3 -c "import json; print(json.load(open('${manifest}'))['dbhost'])" 2>/dev/null || \
                   php -r "echo json_decode(file_get_contents('${manifest}'))->dbhost;" 2>/dev/null || true)"
    fi
    if [[ -z "${DB_NAME}" ]]; then
        DB_NAME="$(python3 -c "import json; print(json.load(open('${manifest}'))['dbname'])" 2>/dev/null || \
                   php -r "echo json_decode(file_get_contents('${manifest}'))->dbname;" 2>/dev/null || true)"
    fi
    if [[ -z "${DB_USER}" ]]; then
        DB_USER="$(python3 -c "import json; print(json.load(open('${manifest}'))['dbuser'])" 2>/dev/null || \
                   php -r "echo json_decode(file_get_contents('${manifest}'))->dbuser;" 2>/dev/null || true)"
    fi

    log_info "Target webroot: ${WEBROOT}"
    log_info "Target dataroot: ${DATAROOT}"
    log_info "Database: ${DB_NAME}@${DB_HOST}"
}

mysql_client() {
    if command -v mariadb >/dev/null 2>&1; then
        echo "mariadb"
    else
        echo "mysql"
    fi
}

restore_code() {
    log_info "Restoring Moodle code to ${WEBROOT}..."
    local parent target_name archived_name
    parent="$(dirname "${WEBROOT}")"
    target_name="$(basename "${WEBROOT}")"
    mkdir -p "${parent}"

    archived_name="$(tar -tzf "${WORK_DIR}/moodlecode.tar.gz" | head -1 | cut -d/ -f1 | tr -d '\r')"
    tar -xzf "${WORK_DIR}/moodlecode.tar.gz" -C "${parent}"

    if [[ -n "${archived_name}" && "${archived_name}" != "${target_name}" ]]; then
        rm -rf "${WEBROOT}"
        mv "${parent}/${archived_name}" "${WEBROOT}"
    fi
    log_info "Code restored"
}

restore_moodledata() {
    log_info "Restoring moodledata to ${DATAROOT}..."
    local parent target_name archived_name
    parent="$(dirname "${DATAROOT}")"
    target_name="$(basename "${DATAROOT}")"
    mkdir -p "${parent}"

    archived_name="$(tar -tzf "${WORK_DIR}/moodledata.tar.gz" | head -1 | cut -d/ -f1 | tr -d '\r')"
    tar -xzf "${WORK_DIR}/moodledata.tar.gz" -C "${parent}"

    if [[ -n "${archived_name}" && "${archived_name}" != "${target_name}" ]]; then
        rm -rf "${DATAROOT}"
        mv "${parent}/${archived_name}" "${DATAROOT}"
    fi
    log_info "Moodledata restored"
}

restore_database() {
    if [[ "${SKIP_DB}" == "true" ]]; then
        log_info "Skipping database restore (--skip-db)"
        return 0
    fi

    if [[ -z "${DB_PASS}" ]]; then
        read -r -s -p "Database password for ${DB_USER}: " DB_PASS
        echo
    fi

    local client defaults_file
    client="$(mysql_client)"
    defaults_file="$(mktemp)"
    chmod 600 "${defaults_file}"
    cat > "${defaults_file}" <<EOF
[client]
host=${DB_HOST}
user=${DB_USER}
password=${DB_PASS}
EOF

    if [[ "${DB_CREATE}" == "true" ]]; then
        log_info "Creating database ${DB_NAME} if not exists..."
        "${client}" --defaults-extra-file="${defaults_file}" -e \
            "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
            || { rm -f "${defaults_file}"; exit "${EXIT_DATABASE}"; }
    fi

    log_info "Importing database ${DB_NAME}..."
    if ! gunzip -c "${WORK_DIR}/database.sql.gz" | \
        "${client}" --defaults-extra-file="${defaults_file}" "${DB_NAME}"; then
        rm -f "${defaults_file}"
        log_error "Database import failed"
        exit "${EXIT_DATABASE}"
    fi
    rm -f "${defaults_file}"
    log_info "Database imported"
}

update_config_php() {
    local cfg="${WEBROOT}/config.php"
    if [[ ! -f "${cfg}" ]]; then
        log_warn "config.php not found at ${cfg} — update manually"
        return 0
    fi

    log_info "Updating config.php paths and database settings..."
    php -r "
\$f = '${cfg}';
\$c = file_get_contents(\$f);
\$set = function (\$key, \$val) use (&\$c) {
    \$pat = '/\\\\\\$CFG->' . preg_quote(\$key, '/') . '\\\\s*=\\\\s*.*?;/s';
    \$rep = '\$CFG->' . \$key . ' = ' . var_export(\$val, true) . ';';
    if (preg_match(\$pat, \$c)) {
        \$c = preg_replace(\$pat, \$rep, \$c);
    }
};
\$set('dataroot', '${DATAROOT}');
\$set('dbhost', '${DB_HOST}');
\$set('dbname', '${DB_NAME}');
\$set('dbuser', '${DB_USER}');
if ('${DB_PASS}' !== '') {
    \$set('dbpass', '${DB_PASS}');
}
if ('${REPLACE_WITH}' !== '') {
    \$set('wwwroot', '${REPLACE_WITH}');
}
file_put_contents(\$f, \$c);
" || log_warn "Could not auto-update config.php — edit manually"
}

post_restore() {
    if [[ -f "${WEBROOT}/admin/cli/purge_caches.php" ]]; then
        log_info "Purging Moodle caches..."
        php "${WEBROOT}/admin/cli/purge_caches.php" || log_warn "purge_caches failed"
    fi

    if [[ -n "${REPLACE_URL}" && -n "${REPLACE_WITH}" ]]; then
        local replace_cli="${WEBROOT}/admin/tool/replace/cli/replace.php"
        if [[ -f "${replace_cli}" ]]; then
            log_info "Replacing URL ${REPLACE_URL} -> ${REPLACE_WITH}..."
            php "${replace_cli}" \
                --search="${REPLACE_URL}" \
                --replace="${REPLACE_WITH}" \
                --non-interactive || log_warn "URL replace failed"
        else
            log_warn "replace.php not found — run URL replacement manually"
        fi
    fi

    if command -v chown >/dev/null 2>&1; then
        local web_user="${APACHE_RUN_USER:-www-data}"
        if chown "${web_user}:${web_user}" "${WEBROOT}/config.php" 2>/dev/null; then
            log_info "Set ownership on config.php to ${web_user}"
        else
            log_warn "Cannot chown — run as root or adjust permissions manually"
        fi
    fi
}

cleanup_workdir() {
    :
}

main() {
    parse_args "$@"
    resolve_archive

    log_info "Moodle restore started (user: $(whoami))"
    log_info "Source: ${ARCHIVE_PATH}"

    prepare_backup_files
    read_manifest

    if [[ -z "${WEBROOT}" || -z "${DATAROOT}" ]]; then
        log_error "webroot/dataroot not set and not found in manifest"
        exit "${EXIT_CONFIG}"
    fi

    check_rw_access "${WEBROOT}" "webroot"
    check_rw_access "${DATAROOT}" "moodledata"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[dry-run] Permissions OK. Would restore to ${WEBROOT} and ${DATAROOT}"
        cleanup_workdir
        exit "${EXIT_OK}"
    fi

    restore_code
    restore_moodledata
    restore_database
    update_config_php
    post_restore

    log_info "Restore completed successfully"
    cleanup_workdir
}

trap cleanup_workdir EXIT
main "$@"

#!/usr/bin/env bash
# One-time ACL setup for Moodle backup user on moodledata.
# Must be run as root (or with CAP_FOWNER) on the Moodle host.
#
# Usage:
#   sudo ./setup-moodledata-acl.sh --user scripter --dataroot /data/moodata
#   sudo ./setup-moodledata-acl.sh --moodle-root /var/www/moodle --user scripter
#   ./setup-moodledata-acl.sh --check-only --dataroot /data/moodata

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/moodle-backup.env"

BACKUP_USER=""
DATAROOT=""
MOODLE_ROOT=""
CHECK_ONLY=false
SKIP_CLI_BOOTSTRAP=false

usage() {
    cat <<EOF
Usage: setup-moodledata-acl.sh [options]

Grant the backup user read access to moodledata (for backups), write access
to the dataroot directory (for climaintenance.html / backup-notice.json), and
write ACL on Moodle CLI bootstrap dirs (temp, cache, localcache, muc) so
quiz_backup.php can run as the backup user (no sudo).

Options:
  --user USER           Backup account (default: current user)
  --dataroot PATH       Moodle dataroot directory
  --moodle-root PATH    Moodle code root (dataroot + bootstrap paths from config.php)
  --skip-cli-bootstrap  Do not apply write ACL on temp/cache/localcache/muc
  --check-only          Verify effective permissions (ACL tools optional)
  -h, --help            Show this help

Examples:
  sudo $0 --user scripter --dataroot /data/moodata
  sudo $0 --moodle-root /var/www/moodle --user scripter
  $0 --check-only --dataroot /data/moodata

Full setup requires: setfacl, getfacl (package 'acl' on Debian/Ubuntu: apt install acl)
EOF
}

log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

current_user_name() {
    id -un 2>/dev/null || echo ""
}

# Run a command as BACKUP_USER: direct if already that user, sudo -u only when invoked as root.
run_as_backup_user() {
    local current
    current="$(current_user_name)"
    if [[ "${current}" == "${BACKUP_USER}" ]]; then
        "$@"
        return $?
    fi
    if [[ "${EUID}" -eq 0 ]]; then
        sudo -u "${BACKUP_USER}" "$@"
        return $?
    fi
    log_error "Cannot run as ${BACKUP_USER}: invoke this script as root or as ${BACKUP_USER} (current: ${current})"
    return 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)        BACKUP_USER="$2"; shift 2 ;;
            --dataroot)    DATAROOT="$2"; shift 2 ;;
            --moodle-root) MOODLE_ROOT="$2"; shift 2 ;;
            --skip-cli-bootstrap) SKIP_CLI_BOOTSTRAP=true; shift ;;
            --check-only)  CHECK_ONLY=true; shift ;;
            -h|--help)     usage; exit 0 ;;
            *) log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

load_defaults() {
    if [[ -f "${ENV_FILE}" ]]; then
        # shellcheck disable=SC1090
        set -a
        # Strip CR from env values (Windows-deployed env file)
        eval "$(tr -d '\r' < "${ENV_FILE}")"
        set +a
        MOODLE_ROOT="${MOODLE_ROOT:-${BACKUPER_LOCATION:-}}"
        BACKUP_USER="${BACKUP_USER:-${BACKUPER_LOGIN:-}}"
    fi
}

resolve_dataroot() {
    if [[ -n "${DATAROOT}" ]]; then
        return 0
    fi
    if [[ -z "${MOODLE_ROOT}" ]]; then
        log_error "Specify --dataroot or --moodle-root"
        exit 1
    fi
    local parser="${SCRIPT_DIR}/lib/parse_config.php"
    local parse_err
    if [[ ! -f "${parser}" ]]; then
        log_error "parse_config.php not found. Deploy scripts first or pass --dataroot"
        exit 1
    fi
    parse_err="$(mktemp)"
    if ! DATAROOT="$(php "${parser}" "${MOODLE_ROOT}" --get dataroot 2>"${parse_err}")"; then
        log_error "Could not read dataroot from ${MOODLE_ROOT}/config.php"
        if [[ -s "${parse_err}" ]]; then
            log_error "$(cat "${parse_err}")"
        fi
        rm -f "${parse_err}"
        exit 1
    fi
    rm -f "${parse_err}"
}

require_backup_user() {
    if [[ -z "${BACKUP_USER}" ]]; then
        BACKUP_USER="$(current_user_name)"
    fi
    if [[ -z "${BACKUP_USER}" ]]; then
        log_error "Specify --user (backup account name)"
        exit 1
    fi
    if ! id "${BACKUP_USER}" >/dev/null 2>&1; then
        log_error "User not found: ${BACKUP_USER}"
        exit 1
    fi
}

check_acl_tools() {
    local missing=()
    for cmd in setfacl getfacl; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "ACL utilities not found: ${missing[*]}"
        log_error "Install the acl package, for example:"
        log_error "  Debian/Ubuntu: apt install acl"
        log_error "  RHEL/CentOS:   yum install acl"
        return 1
    fi
    log_info "ACL tools present: setfacl, getfacl"
    return 0
}

check_acl_filesystem() {
    local target="$1"
    local probe="${target}/.moobackup_acl_fs_probe"

    if [[ ! -d "${target}" ]]; then
        log_error "Directory not found: ${target}"
        return 1
    fi

    if ! touch "${probe}" 2>/dev/null; then
        log_error "Cannot create probe file in ${target} (run as root?)"
        return 1
    fi

    if ! setfacl -m "u:${BACKUP_USER}:rx" "${probe}" 2>/dev/null; then
        rm -f "${probe}"
        log_error "Filesystem at ${target} does not support POSIX ACL"
        log_error "Ensure the volume is mounted with acl option (e.g. acl in /etc/fstab for ext4)"
        return 1
    fi

    rm -f "${probe}"
    log_info "Filesystem supports ACL on ${target}"
    return 0
}

apply_acls() {
    local target="$1"
    log_info "Applying ACL for user ${BACKUP_USER} on ${target}..."

    setfacl -R -m "u:${BACKUP_USER}:rx" "${target}"
    setfacl -R -m "d:u:${BACKUP_USER}:rx" "${target}"
    setfacl -m "u:${BACKUP_USER}:rwx" "${target}"

    log_info "ACL applied (read tree + write dataroot root)"
}

list_cli_bootstrap_dirs() {
    local parser="${SCRIPT_DIR}/lib/parse_config.php"
    if [[ ! -f "${parser}" ]]; then
        log_error "parse_config.php not found. Deploy scripts first."
        return 1
    fi
    if [[ -n "${MOODLE_ROOT}" ]]; then
        php "${parser}" "${MOODLE_ROOT}" --bootstrap-dirs
        return 0
    fi
    php "${parser}" --bootstrap-dirs-dataroot "${DATAROOT}"
}

apply_cli_bootstrap_acls() {
    local parser="${SCRIPT_DIR}/lib/parse_config.php"
    local dir

    if [[ "${SKIP_CLI_BOOTSTRAP}" == "true" ]]; then
        log_info "Skipping CLI bootstrap ACL (--skip-cli-bootstrap)"
        return 0
    fi

    if [[ ! -f "${parser}" ]]; then
        log_warn "parse_config.php missing — skip CLI bootstrap ACL"
        return 0
    fi

    log_info "Applying CLI bootstrap write ACL (temp/cache/localcache/muc)..."

    while IFS= read -r dir; do
        [[ -n "${dir}" ]] || continue
        if [[ ! -d "${dir}" ]]; then
            log_warn "  skip missing directory: ${dir}"
            continue
        fi
        log_info "  ${dir}"
        setfacl -R -m "u:${BACKUP_USER}:rwx" "${dir}"
        setfacl -R -d -m "u:${BACKUP_USER}:rwx" "${dir}"
    done < <(list_cli_bootstrap_dirs)

    log_info "CLI bootstrap ACL applied"
}

check_cli_bootstrap_access() {
    local parser="${SCRIPT_DIR}/lib/parse_config.php"
    local quiz_script="${SCRIPT_DIR}/lib/quiz_backup.php"
    local dir ok=true probe

    log_info "Checking CLI bootstrap write access..."

    while IFS= read -r dir; do
        [[ -n "${dir}" ]] || continue
        if [[ ! -d "${dir}" ]]; then
            log_warn "  ${dir}: missing (skipped)"
            continue
        fi
        probe="${dir}/.moobackup_cli_bootstrap_probe_$$"
        if run_as_backup_user bash -c "echo test > '${probe}'" 2>/dev/null; then
            run_as_backup_user rm -f "${probe}"
            log_info "  write ${dir}: OK"
        else
            log_error "  write ${dir}: DENIED"
            ok=false
        fi
    done < <(list_cli_bootstrap_dirs 2>/dev/null || true)

    if [[ -f "${quiz_script}" && -n "${MOODLE_ROOT}" && -d "${MOODLE_ROOT}" ]]; then
        log_info "Checking quiz_backup.php list as ${BACKUP_USER} (no sudo)..."
        if run_as_backup_user php "${quiz_script}" list --moodle-root="${MOODLE_ROOT}" >/dev/null 2>&1; then
            log_info "  quiz_backup.php list: OK"
        else
            log_warn "  quiz_backup.php list: FAILED (re-run setup-moodledata-acl.sh with --moodle-root)"
            ok=false
        fi
    fi

    if [[ "${ok}" == "true" ]]; then
        return 0
    fi
    return 1
}

show_effective_acl() {
    local target="$1"
    if ! command -v getfacl >/dev/null 2>&1; then
        return 0
    fi
    log_info "Effective ACL on ${target}:"
    getfacl -p "${target}" 2>/dev/null | sed -n '1,20p' || log_warn "  getfacl failed (ACL may be unsupported on this filesystem)"
}

print_reminder() {
    cat >&2 <<EOF

To fix permissions:
  - If POSIX ACL is available, run once as root:
      sudo ${SCRIPT_DIR}/setup-moodledata-acl.sh --user ${BACKUP_USER} --moodle-root /var/www/moodle
      # or: --dataroot ${DATAROOT}
  - Otherwise grant ${BACKUP_USER} read/traverse on dataroot, write on dataroot root,
    and write on Moodle CLI bootstrap dirs (temp/cache/localcache/muc).

EOF
}

run_acl_preflight() {
    check_acl_tools
    check_acl_filesystem "${DATAROOT}"
}

run_check_only() {
    log_info "Check-only mode — verifying effective access for ${BACKUP_USER}"

    if command -v getfacl >/dev/null 2>&1; then
        show_effective_acl "${DATAROOT}"
    else
        log_info "getfacl not available — checking effective access only"
    fi

    local ok=true
    check_backup_user_access "${DATAROOT}" || ok=false
    if [[ "${SKIP_CLI_BOOTSTRAP}" != "true" ]]; then
        check_cli_bootstrap_access || ok=false
    fi
    if [[ "${ok}" == "true" ]]; then
        log_info "Permission check passed"
        exit 0
    fi
    print_reminder
    exit 1
}

check_backup_user_access() {
    local target="$1"
    local ok=true

    log_info "Checking access as user ${BACKUP_USER}..."

    if run_as_backup_user test -r "${target}"; then
        log_info "  read on dataroot: OK"
    else
        log_error "  read on dataroot: DENIED"
        ok=false
    fi

    if run_as_backup_user test -x "${target}"; then
        log_info "  traverse dataroot: OK"
    else
        log_error "  traverse dataroot: DENIED"
        ok=false
    fi

    local probe="${target}/.moobackup_acl_write_probe"
    if run_as_backup_user bash -c "echo test > '${probe}'" 2>/dev/null; then
        run_as_backup_user rm -f "${probe}"
        log_info "  create file in dataroot (maintenance mode): OK"
    else
        log_warn "  create file in dataroot (maintenance mode): DENIED"
        log_warn "  Maintenance mode will be skipped during backup until this is fixed"
        ok=false
    fi

    if [[ "${ok}" == "true" ]]; then
        log_info "All required permissions verified"
        return 0
    fi
    return 1
}

main() {
    parse_args "$@"
    load_defaults
    resolve_dataroot
    require_backup_user

    log_info "Backup user: ${BACKUP_USER}"
    log_info "Moodle dataroot: ${DATAROOT}"

    if [[ "${CHECK_ONLY}" == "true" ]]; then
        run_check_only
    fi

    if ! run_acl_preflight; then
        exit 1
    fi

    if [[ "${EUID}" -ne 0 ]]; then
        log_error "ACL setup must be run as root (use sudo)"
        log_error "To verify only: $0 --check-only --dataroot ${DATAROOT}"
        exit 1
    fi

    apply_acls "${DATAROOT}"
    apply_cli_bootstrap_acls
    show_effective_acl "${DATAROOT}"

    local ok=true
    check_backup_user_access "${DATAROOT}" || ok=false
    if [[ "${SKIP_CLI_BOOTSTRAP}" != "true" ]]; then
        check_cli_bootstrap_access || ok=false
    fi
    if [[ "${ok}" == "true" ]]; then
        log_info "Setup complete"
        exit 0
    fi

    log_error "ACL applied but verification failed — review getfacl output above"
    exit 1
}

main "$@"

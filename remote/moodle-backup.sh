#!/usr/bin/env bash
# Moodle full site backup — run on Linux host (console or cron).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/permissions.sh
source "${SCRIPT_DIR}/lib/permissions.sh"
# shellcheck source=lib/progress.sh
source "${SCRIPT_DIR}/lib/progress.sh"
# shellcheck source=lib/maintenance.sh
source "${SCRIPT_DIR}/lib/maintenance.sh"
# shellcheck source=lib/database.sh
source "${SCRIPT_DIR}/lib/database.sh"
# shellcheck source=lib/archive.sh
source "${SCRIPT_DIR}/lib/archive.sh"
# shellcheck source=lib/backup_notice.sh
source "${SCRIPT_DIR}/lib/backup_notice.sh"
# shellcheck source=lib/quiz.sh
source "${SCRIPT_DIR}/lib/quiz.sh"
# shellcheck source=lib/plugins.sh
source "${SCRIPT_DIR}/lib/plugins.sh"

FINAL_EXIT_CODE=0

cleanup() {
    local code=$?
    local saved_step="${ERROR_STEP:-}"
    if [[ ${code} -ne 0 ]]; then
        FINAL_EXIT_CODE=${code}
    fi

    disable_maintenance || true
    if [[ -n "${saved_step}" ]]; then
        ERROR_STEP="${saved_step}"
    fi

    remove_mysql_defaults_file || true
    remove_backup_notice || true
    backup_control_clear || true

    if [[ ${FINAL_EXIT_CODE} -ne 0 && -n "${BACKUP_DIR:-}" ]]; then
        write_error_log "${FINAL_EXIT_CODE}" || true
    fi

    exit "${FINAL_EXIT_CODE}"
}

main() {
    parse_backup_args "$@"
    load_env
    init_backup_dirs
    echo "@BACKUP_DIR ${BACKUP_DIR}"
    init_logging
    require_commands
    check_disk_space
    load_moodle_config
    verify_acl_tools_available || true
    check_dataroot_maintenance_write "${MOODLE_CFG_dataroot}" || true

    trap cleanup EXIT

    if [[ "${BACKUP_SIMULATE}" == "true" ]]; then
        log_warn "Backup simulate mode — database/code/moodledata will not be archived (${BACKUP_SIMULATE_SECONDS}s delay)"
    fi

    if [[ "${BACKUP_QUIZ_PREP}" == "true" ]]; then
        if [[ ! -f "$(quiz_php_script)" ]]; then
            log_error "quiz_backup.php not found — deploy scripts or use --no-quiz-prep"
            exit "${EXIT_QUIZ}"
        fi
        prepare_quiz_for_backup
        wait_for_open_quiz_attempts
    fi

    enable_maintenance

    if [[ "${BACKUP_SIMULATE}" == "true" ]]; then
        simulate_backup_data
    else
        backup_database
        backup_moodle_code
        backup_moodledata
    fi
    finalize_backup

    disable_maintenance
    trap - EXIT
    log_info "Backup finished successfully"
}

main "$@"

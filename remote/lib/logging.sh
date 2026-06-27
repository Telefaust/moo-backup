#!/usr/bin/env bash
# Logging helpers for Moodle backup.

LOGGING_TEE_ACTIVE=false

log_msg() {
    local level="$1"
    shift
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    echo "${line}"
    # init_logging redirects stdout through tee into LOG_FILE — avoid double-write
    if [[ "${LOGGING_TEE_ACTIVE}" != "true" && -n "${LOG_FILE:-}" ]]; then
        echo "${line}" >> "${LOG_FILE}"
    fi
}

log_info()  { log_msg "INFO" "$@"; }
log_warn()  { log_msg "WARN" "$@"; }
log_error() { log_msg "ERROR" "$@"; }

init_logging() {
    : > "${LOG_FILE}"
    exec > >(tee -a "${LOG_FILE}") 2>&1
    LOGGING_TEE_ACTIVE=true
    log_info "Backup started"
    log_info "Moodle root: ${MOODLE_ROOT}"
    log_info "Storage: ${BACKUPER_STORAGE_PATH}"
    log_info "Backup directory: ${BACKUP_DIR}"
    log_info "Full moodledata: ${BACKUP_FULL}"
}

write_error_log() {
    local exit_code="$1"
    local error_file="${BACKUP_DIR}/backup.error.log"
    local storage_error="${BACKUPER_STORAGE_PATH}/$(basename "${BACKUP_DIR}").error.log"

    {
        echo "Moodle backup failed"
        echo "Timestamp: $(date -Iseconds 2>/dev/null || date)"
        echo "Exit code: ${exit_code}"
        echo "Failed step: ${ERROR_STEP:-unknown}"
        echo "--- Last 50 log lines ---"
        if [[ -f "${LOG_FILE}" ]]; then
            tail -n 50 "${LOG_FILE}"
        fi
    } > "${error_file}"

    cp -f "${error_file}" "${storage_error}"
    log_error "Error log written: ${error_file}"
    log_error "Error log duplicated: ${storage_error}"
}

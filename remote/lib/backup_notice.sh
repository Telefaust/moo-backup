#!/usr/bin/env bash
# Backup notice banner control (local_backupnotice plugin).
# Writes or removes dataroot/backup-notice.json.

backup_notice_path() {
    if [[ -z "${MOODLE_CFG_dataroot:-}" ]]; then
        echo ""
        return 1
    fi
    echo "${MOODLE_CFG_dataroot}/backup-notice.json"
}

write_backup_notice() {
    local message="${1:-}"
    local maintenance_at="${2:-}"
    local poll_seconds="${3:-60}"
    local path ts

    path="$(backup_notice_path)" || {
        log_warn "Cannot write backup notice: dataroot unknown"
        return 1
    }

    if [[ ! -d "${MOODLE_CFG_dataroot}" ]]; then
        log_warn "Cannot write backup notice: dataroot missing"
        return 1
    fi

    if [[ ! -w "${MOODLE_CFG_dataroot}" ]]; then
        log_warn "Cannot write backup notice: no write access to ${MOODLE_CFG_dataroot}"
        return 1
    fi

    ts="$(date -Iseconds 2>/dev/null || date)"

    if [[ -z "${maintenance_at}" ]]; then
        maintenance_at="$(date -d '+30 minutes' -Iseconds 2>/dev/null || date -v+30M -Iseconds 2>/dev/null || echo "")"
    fi

    if [[ -z "${message}" ]]; then
        message="Backup soon / finish tests · Скоро бэкап / завершите тесты"
    fi

    BN_PATH="${path}" \
    BN_MESSAGE="${message}" \
    BN_MAINTENANCE_AT="${maintenance_at}" \
    BN_POLL="${poll_seconds}" \
    BN_CREATED="${ts}" \
    php -r '
        $path = getenv("BN_PATH");
        $data = [
            "message" => getenv("BN_MESSAGE"),
            "maintenance_at" => getenv("BN_MAINTENANCE_AT") ?: null,
            "poll_seconds" => (int) (getenv("BN_POLL") ?: 60),
            "created_at" => getenv("BN_CREATED"),
            "block_new_quiz_attempts" => true,
        ];
        file_put_contents($path, json_encode($data, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT) . "\n");
    ' || {
        log_warn "Failed to write backup notice JSON"
        return 1
    }

    log_info "Backup notice written: ${path}"
}

remove_backup_notice() {
    local path
    path="$(backup_notice_path)" || return 0

    if [[ -f "${path}" ]]; then
        rm -f "${path}"
        log_info "Backup notice removed: ${path}"
    fi
}

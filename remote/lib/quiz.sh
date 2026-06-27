#!/usr/bin/env bash
# Quiz preparation and wait logic for Moodle backup.

BACKUP_CONTROL_FILE=""
BACKUP_QUIZ_PREP=true
BACKUP_FORCE=false
BACKUP_QUIZ_POLL="${BACKUP_QUIZ_POLL:-30}"
BACKUP_QUIZ_BUFFER="${BACKUP_QUIZ_BUFFER:-120}"
BACKUP_QUIZ_UNKNOWN_MAX="${BACKUP_QUIZ_UNKNOWN_MAX:-3600}"

quiz_php_script() {
    echo "${LIB_DIR}/quiz_backup.php"
}

quiz_php_bin() {
    if [[ -n "${MOOBACKUP_QUIZ_PHP:-}" ]]; then
        if [[ -x "${MOOBACKUP_QUIZ_PHP}" ]]; then
            echo "${MOOBACKUP_QUIZ_PHP}"
            return 0
        fi
        echo ""
        return 1
    fi
    if [[ -x /usr/bin/php ]]; then
        echo "/usr/bin/php"
        return 0
    fi
    local php
    php="$(command -v php 2>/dev/null || true)"
    if [[ -z "${php}" || ! -x "${php}" ]]; then
        echo ""
        return 1
    fi
    echo "${php}"
}

quiz_php() {
    local script php_bin
    script="$(readlink -f "$(quiz_php_script)" 2>/dev/null || quiz_php_script)"
    php_bin="$(quiz_php_bin)" || {
        log_error "php not found for quiz_backup.php (set MOOBACKUP_QUIZ_PHP in moodle-backup.env)"
        return 1
    }

    "${php_bin}" "${script}" "$@" --moodle-root="${MOODLE_ROOT}"
}

# Capture stdout to a file — avoids losing JSON under "exec > tee" in init_logging.
quiz_php_capture() {
    local tmp errtmp rc
    tmp="$(mktemp "${TMPDIR:-/tmp}/moobackup-quiz.XXXXXX")"
    errtmp="${tmp}.err"

    quiz_php "$@" > "${tmp}" 2>"${errtmp}"
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        if [[ -s "${errtmp}" ]]; then
            log_error "$(tr '\n' ' ' < "${errtmp}")"
        fi
        if [[ -s "${tmp}" ]]; then
            log_error "$(tr '\n' ' ' < "${tmp}")"
        fi
    fi

    cat "${tmp}"
    rm -f "${tmp}" "${errtmp}"
    return "${rc}"
}

verify_quiz_runner() {
    local php_bin script current_user
    current_user="$(id -un 2>/dev/null || echo "")"
    php_bin="$(quiz_php_bin)" || {
        log_error "Quiz runner: php binary not found"
        exit "${EXIT_QUIZ}"
    }
    script="$(readlink -f "$(quiz_php_script)" 2>/dev/null || quiz_php_script)"

    log_info "Quiz runner: ${current_user} (quiz_backup.php via Moodle CLI bootstrap)"
    if "${php_bin}" "${script}" list --moodle-root="${MOODLE_ROOT}" >/dev/null 2>&1; then
        return 0
    fi
    log_error "Quiz runner check failed for ${current_user}."
    log_error "Run once as root: sudo ${REMOTE_BIN_DIR}/setup-moodledata-acl.sh --user ${current_user} --moodle-root ${MOODLE_ROOT}"
    exit "${EXIT_QUIZ}"
}

quiz_extract_json() {
    php -r '
        $in = stream_get_contents(STDIN);
        if ($in === false || $in === "") {
            fwrite(STDERR, "empty quiz_backup.php response\n");
            exit(1);
        }
        if (preg_match("/\{.*\}/s", $in, $m)) {
            echo $m[0];
            exit(0);
        }
        fwrite(STDERR, "no JSON object in response: " . substr($in, 0, 500) . "\n");
        exit(1);
    '
}

init_quiz_backup_paths() {
    BACKUP_CONTROL_FILE="${BACKUP_DIR}/control"
    rm -f "${BACKUP_CONTROL_FILE}"
}

backup_control_read() {
    if [[ ! -f "${BACKUP_CONTROL_FILE}" ]]; then
        echo ""
        return 0
    fi
    tr -d '\r\n' < "${BACKUP_CONTROL_FILE}"
}

backup_control_clear() {
    rm -f "${BACKUP_CONTROL_FILE}"
}

quiz_list_json() {
    local raw json
    raw="$(quiz_php_capture list)" || return 1
    json="$(printf '%s' "${raw}" | quiz_extract_json)" || {
        log_error "quiz list: could not parse JSON (got: ${raw:0:200})"
        return 1
    }
    printf '%s' "${json}"
}

quiz_count_open() {
    local json count
    json="$(quiz_list_json)" || return 1
    count="$(php -r '
        $j = json_decode(stream_get_contents(STDIN), true);
        if (!is_array($j) || !isset($j["count"])) {
            exit(1);
        }
        echo (int) $j["count"];
    ' <<< "${json}")" || {
        log_error "quiz list: invalid count in JSON"
        return 1
    }
    echo "${count}"
}

quiz_max_seconds_left() {
    local json
    json="$(quiz_list_json)" || return 1
    php -r '
        $j = json_decode(stream_get_contents(STDIN), true);
        if (!is_array($j)) { echo -1; exit; }
        if (!empty($j["has_unknown_deadline"]) && ($j["max_seconds_left"] ?? null) === null) {
            echo -2;
            exit;
        }
        echo isset($j["max_seconds_left"]) && $j["max_seconds_left"] !== null ? (int)$j["max_seconds_left"] : 0;
    ' <<< "${json}"
}

report_quiz_attempts() {
    local json
    json="$(quiz_list_json)" || return 1
    echo "@QUIZ_ATTEMPTS ${json}"
}

quiz_open_count_or_fail() {
    local count
    if ! count="$(quiz_count_open)"; then
        log_error "Failed to list open quiz attempts"
        exit "${EXIT_QUIZ}"
    fi
    echo "${count}"
}

quiz_max_seconds_left_or_default() {
    local maxleft
    if ! maxleft="$(quiz_max_seconds_left)"; then
        log_warn "Failed to read quiz attempt deadlines — using default wait"
        echo "-1"
        return 0
    fi
    echo "${maxleft}"
}

compute_banner_maintenance_at() {
    local maxleft="$1"
    local target
    if [[ "${maxleft}" -lt 0 ]]; then
        target=$(( $(date +%s) + BACKUP_QUIZ_UNKNOWN_MAX + BACKUP_QUIZ_BUFFER ))
    else
        target=$(( $(date +%s) + maxleft + BACKUP_QUIZ_BUFFER ))
    fi
    date -d "@${target}" -Iseconds 2>/dev/null || date -r "${target}" -Iseconds 2>/dev/null || echo ""
}

quiz_require_backupnotice_access() {
    local out json installed
    if ! out="$(quiz_php_capture env-check)"; then
        log_error "Could not run quiz_backup.php env-check"
        exit "${EXIT_QUIZ}"
    fi
    json="$(printf '%s' "${out}" | quiz_extract_json)" || {
        log_error "env-check: invalid JSON"
        exit "${EXIT_QUIZ}"
    }
    installed="$(php -r '
        $j = json_decode(stream_get_contents(STDIN), true);
        echo (is_array($j) && !empty($j["quizaccess_backupnotice_installed"])) ? "1" : "0";
    ' <<< "${json}")"
    if [[ "${installed}" != "1" ]]; then
        log_error "quizaccess_backupnotice is not installed — required to block new quiz attempts during backup"
        log_error "Install: moodle-plugin/dist/quizaccess_backupnotice_moodle40-*.zip (see README)"
        exit "${EXIT_QUIZ}"
    fi
    log_info "quizaccess_backupnotice: OK (new quiz attempts blocked via backup-notice.json)"
}

prepare_quiz_for_backup() {
    ERROR_STEP="prepare_quiz_for_backup"
    local count maxleft maintenance_at

    init_quiz_backup_paths
    verify_quiz_runner
    quiz_require_backupnotice_access

    count="$(quiz_open_count_or_fail)"
    maxleft="$(quiz_max_seconds_left_or_default)"

    log_info "Open quiz attempts before preparation: ${count}"
    report_quiz_attempts || log_warn "Could not report quiz attempts to GUI"

    maintenance_at="$(compute_banner_maintenance_at "${maxleft}")"
    write_backup_notice "" "${maintenance_at}" "${BACKUP_QUIZ_POLL}"
}

wait_for_open_quiz_attempts() {
    ERROR_STEP="wait_for_open_quiz_attempts"
    local count maxleft waited=0 wait_limit unknown_limit="${BACKUP_QUIZ_UNKNOWN_MAX}"
    local start_epoch end_epoch now

    if [[ "${BACKUP_FORCE}" == "true" ]]; then
        log_warn "Skipping quiz wait (--force)"
        return 0
    fi

    count="$(quiz_open_count_or_fail)"
    if [[ "${count}" -eq 0 ]]; then
        log_info "No open quiz attempts — continuing"
        return 0
    fi

    maxleft="$(quiz_max_seconds_left_or_default)"
    if [[ "${maxleft}" -eq -2 ]]; then
        wait_limit="${unknown_limit}"
        log_warn "Open quiz attempts without known deadline — waiting up to ${wait_limit}s (force to skip)"
    elif [[ "${maxleft}" -gt 0 ]]; then
        wait_limit=$(( maxleft + BACKUP_QUIZ_BUFFER ))
    else
        wait_limit="${BACKUP_QUIZ_BUFFER}"
    fi

    start_epoch="$(date +%s)"
    end_epoch=$(( start_epoch + wait_limit ))

    log_info "Waiting for ${count} open quiz attempt(s), up to ${wait_limit}s (poll ${BACKUP_QUIZ_POLL}s)"
    echo "@BACKUP_WAIT start ${wait_limit} ${BACKUP_QUIZ_POLL}"

    while true; do
        local control
        control="$(backup_control_read)"
        if [[ "${control}" == "cancel" ]]; then
            log_warn "Backup cancelled by operator during quiz wait"
            backup_control_clear
            remove_backup_notice || true
            exit "${EXIT_CANCELLED}"
        fi
        if [[ "${control}" == "force" ]]; then
            log_warn "Backup forced by operator — proceeding with open quiz attempts"
            backup_control_clear
            return 0
        fi

        count="$(quiz_open_count_or_fail)"
        report_quiz_attempts || log_warn "Could not report quiz attempts to GUI"

        if [[ "${count}" -eq 0 ]]; then
            log_info "All quiz attempts finished"
            echo "@BACKUP_WAIT done 0"
            backup_control_clear
            return 0
        fi

        now="$(date +%s)"
        waited=$(( now - start_epoch ))
        if [[ "${now}" -ge "${end_epoch}" ]]; then
            log_warn "Quiz wait timeout (${wait_limit}s) with ${count} attempt(s) still open — continuing"
            echo "@BACKUP_WAIT timeout ${count}"
            backup_control_clear
            return 0
        fi

        local remaining=$(( end_epoch - now ))
        local pct=0
        if [[ "${wait_limit}" -gt 0 ]]; then
            pct=$(( waited * 100 / wait_limit ))
        fi
        report_progress "quizwait" "${pct}" "${count} open, ~${remaining}s max wait left"
        echo "@BACKUP_WAIT poll ${count} ${remaining}"

        sleep "${BACKUP_QUIZ_POLL}"
    done
}

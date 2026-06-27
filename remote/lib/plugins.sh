#!/usr/bin/env bash
# Third-party Moodle plugin inventory (upgrade reference, not used for restore).

write_contrib_plugins_list() {
    local dest="${BACKUP_DIR}/contrib-plugins.txt"
    local ts list_out count

    ts="$(date -Iseconds 2>/dev/null || date)"

    {
        echo "# Third-party (contrib) Moodle plugins — for admin / upgrade planning"
        echo "# Not required for restore."
        echo "# Source: quiz_backup.php contrib-list (Moodle API)"
        echo "# Generated: ${ts}"
        echo "# Moodle: ${MOODLE_RELEASE:-unknown} (${MOODLE_VERSION:-?})"
        echo "# wwwroot: ${MOODLE_CFG_wwwroot}"
        echo "# Format: component<TAB>display_name"
        echo "#"
    } > "${dest}"

    if ! declare -F quiz_php_capture >/dev/null 2>&1; then
        log_warn "quiz_php_capture not available — deploy latest scripts"
        echo "# ERROR: quiz.sh not loaded" >> "${dest}"
        return 0
    fi

    if list_out="$(quiz_php_capture contrib-list)"; then
        if [[ -n "${list_out}" ]]; then
            printf '%s\n' "${list_out}" >> "${dest}"
            count="$(printf '%s\n' "${list_out}" | wc -l | tr -d ' ')"
            log_info "Contrib plugins: ${count} listed in contrib-plugins.txt"
        else
            echo "# (no third-party plugins installed)" >> "${dest}"
            log_info "Contrib plugins: none installed"
        fi
    else
        log_warn "Failed to list contrib plugins (quiz_backup.php contrib-list)"
        echo "# ERROR: failed to run contrib-list" >> "${dest}"
    fi
}

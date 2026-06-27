#!/usr/bin/env bash
# Database dump for Moodle backup.

mysql_client_binary() {
    if command -v mariadb >/dev/null 2>&1; then
        echo "mariadb"
    else
        echo "mysql"
    fi
}

create_mysql_defaults_file() {
    MYSQL_DEFAULTS_FILE="$(mktemp)"
    chmod 600 "${MYSQL_DEFAULTS_FILE}"
    cat > "${MYSQL_DEFAULTS_FILE}" <<EOF
[client]
host=${MOODLE_CFG_dbhost}
user=${MOODLE_CFG_dbuser}
password=${MOODLE_CFG_dbpass}
EOF
}

remove_mysql_defaults_file() {
    if [[ -n "${MYSQL_DEFAULTS_FILE}" && -f "${MYSQL_DEFAULTS_FILE}" ]]; then
        rm -f "${MYSQL_DEFAULTS_FILE}"
        MYSQL_DEFAULTS_FILE=""
    fi
}

backup_database() {
    ERROR_STEP="backup_database"
    local out="${BACKUP_DIR}/database.sql.gz"
    local dump_cmd client est_bytes

    dump_cmd="$(dump_binary)"
    client="$(mysql_client_binary)"

    log_info "Dumping database ${MOODLE_CFG_dbname}..."

    create_mysql_defaults_file
    est_bytes="$(estimate_database_bytes "${client}" "${MYSQL_DEFAULTS_FILE}" "${MOODLE_CFG_dbname}")"

    if ! run_dump_gzip_progress "database" "${out}" "${dump_cmd}" \
        "${MYSQL_DEFAULTS_FILE}" "${MOODLE_CFG_dbname}" "${est_bytes}"; then
        log_error "Database dump failed"
        remove_mysql_defaults_file
        exit "${EXIT_DATABASE}"
    fi

    remove_mysql_defaults_file

    local size
    size="$(stat -c%s "${out}" 2>/dev/null || stat -f%z "${out}" 2>/dev/null || echo 0)"
    log_info "Database dump complete: $(human_size "${size}")"
}

#!/usr/bin/env bash
# Read Moodle configuration without full application bootstrap.

MOODLE_CFG_dbhost=""
MOODLE_CFG_dbname=""
MOODLE_CFG_dbuser=""
MOODLE_CFG_dbpass=""
MOODLE_CFG_dbtype=""
MOODLE_CFG_wwwroot=""
MOODLE_CFG_dataroot=""
MOODLE_CFG_dbprefix=""
MOODLE_VERSION=""
MOODLE_RELEASE=""

load_moodle_config() {
    ERROR_STEP="load_moodle_config"
    local parser="${LIB_DIR}/parse_config.php"
    local parse_err

    if [[ ! -f "${parser}" ]]; then
        log_error "Config parser not found: ${parser}"
        exit "${EXIT_CONFIG}"
    fi

    parse_err="$(mktemp)"
    if ! shell_vars="$(php "${parser}" "${MOODLE_ROOT}" --shell 2>"${parse_err}")"; then
        log_error "Failed to parse Moodle config.php: $(cat "${parse_err}")"
        rm -f "${parse_err}"
        exit "${EXIT_CONFIG}"
    fi
    rm -f "${parse_err}"

    if ! eval "${shell_vars}"; then
        log_error "Failed to load parsed Moodle configuration"
        exit "${EXIT_CONFIG}"
    fi

    if [[ -z "${MOODLE_CFG_dbname}" || -z "${MOODLE_CFG_dataroot}" ]]; then
        log_error "Failed to read Moodle configuration (dbname/dataroot empty)"
        log_error "Check ${MOODLE_ROOT}/config.php and parse_config.php on the host"
        exit "${EXIT_CONFIG}"
    fi

    if [[ ! -d "${MOODLE_CFG_dataroot}" ]]; then
        log_error "Moodle dataroot not found: ${MOODLE_CFG_dataroot}"
        exit "${EXIT_CONFIG}"
    fi

    if [[ ! -r "${MOODLE_CFG_dataroot}" ]]; then
        log_error "No read access to dataroot: ${MOODLE_CFG_dataroot}"
        exit "${EXIT_CONFIG}"
    fi

    log_info "Moodle ${MOODLE_RELEASE:-unknown} (${MOODLE_VERSION:-?})"
    log_info "wwwroot: ${MOODLE_CFG_wwwroot}"
    log_info "dataroot: ${MOODLE_CFG_dataroot}"
    log_info "database: ${MOODLE_CFG_dbname}@${MOODLE_CFG_dbhost}"
}

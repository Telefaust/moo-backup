#!/usr/bin/env bash
# Check moodledata permissions for backup and maintenance mode.

ACL_SETUP_SCRIPT="${REMOTE_BIN_DIR}/setup-moodledata-acl.sh"

check_dataroot_read_access() {
    local dataroot="$1"
    if [[ ! -r "${dataroot}" || ! -x "${dataroot}" ]]; then
        log_error "No read/traverse access to dataroot: ${dataroot}"
        _permissions_reminder "${dataroot}"
        exit "${EXIT_CONFIG}"
    fi
}

can_create_file_in_dataroot() {
    local dataroot="$1"
    local probe="${dataroot}/.moobackup_write_probe_$$"
    if touch "${probe}" 2>/dev/null; then
        rm -f "${probe}"
        return 0
    fi
    return 1
}

check_dataroot_maintenance_write() {
    local dataroot="$1"
    if can_create_file_in_dataroot "${dataroot}"; then
        log_info "Dataroot write access OK (maintenance mode available)"
        return 0
    fi

    log_warn "Insufficient write access to dataroot for maintenance mode: ${dataroot}"
    _permissions_reminder "${dataroot}"
    return 1
}

_permissions_reminder() {
    local dataroot="$1"
    local user
    user="$(whoami)"
    log_warn "Ensure POSIX ACL is configured for the backup user"
    if [[ -f "${ACL_SETUP_SCRIPT}" ]]; then
        log_warn "Run once as root: sudo ${ACL_SETUP_SCRIPT} --user ${user} --dataroot ${dataroot}"
    else
        log_warn "Run setup-moodledata-acl.sh as root (see project README)"
    fi
    if command -v setfacl >/dev/null 2>&1; then
        :
    else
        log_warn "ACL tools not installed — install package 'acl' (apt install acl)"
    fi
}

verify_acl_tools_available() {
    if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
        return 0
    fi
    log_warn "setfacl/getfacl not found — install package 'acl' to use setup-moodledata-acl.sh"
    return 1
}

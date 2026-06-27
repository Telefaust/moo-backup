#!/usr/bin/env bash
# Archive Moodle code, moodledata, manifest (no extra tarball wrapper).

backup_moodle_code() {
    ERROR_STEP="backup_moodle_code"
    local out="${BACKUP_DIR}/moodlecode.tar.gz"
    local parent name
    parent="$(dirname "${MOODLE_ROOT}")"
    name="$(basename "${MOODLE_ROOT}")"

    log_info "Archiving Moodle code (full tree, no exclusions): ${MOODLE_ROOT}"
    run_tar_gzip_progress "moodlecode" "${out}" "${parent}" "${name}"
}

backup_moodledata() {
    ERROR_STEP="backup_moodledata"
    local out="${BACKUP_DIR}/moodledata.tar.gz"
    local parent name
    parent="$(dirname "${MOODLE_CFG_dataroot}")"
    name="$(basename "${MOODLE_CFG_dataroot}")"
    local -a excludes=()
    local ex

    if [[ "${BACKUP_FULL}" != "true" ]]; then
        while IFS= read -r ex; do
            excludes+=("${ex}")
        done < <(moodledata_excludes)
        log_info "Archiving moodledata (standard, excluding volatile dirs)..."
    else
        log_info "Archiving moodledata (full, no exclusions)..."
    fi

    run_tar_gzip_progress "moodledata" "${out}" "${parent}" "${name}" "${excludes[@]}"
}

simulate_backup_data() {
    ERROR_STEP="simulate_backup_data"
    local delay="${BACKUP_SIMULATE_SECONDS:-5}"
    log_warn "Simulate mode: skipping database, code and moodledata (${delay}s stand-in delay)"
    report_progress "database" 0 "Simulated"
    report_progress "moodlecode" 0 "Simulated"
    report_progress "moodledata" 0 "Simulated"
    sleep "${delay}"
    report_progress "database" 100 "Simulated"
    report_progress "moodlecode" 100 "Simulated"
    report_progress "moodledata" 100 "Simulated"
    log_info "Simulate delay complete (${delay}s)"
}

moodledata_excludes() {
    if [[ "${BACKUP_FULL}" == "true" ]]; then
        return 0
    fi
    echo "--exclude=cache"
    echo "--exclude=localcache"
    echo "--exclude=temp"
    echo "--exclude=sessions"
    echo "--exclude=trashdir"
}

write_manifest() {
    ERROR_STEP="write_manifest"
    local manifest="${BACKUP_DIR}/manifest.json"
    local mode="standard"
    [[ "${BACKUP_FULL}" == "true" ]] && mode="full"
    local simulated="false"
    local simulate_seconds="0"
    [[ "${BACKUP_SIMULATE}" == "true" ]] && simulated="true"
    [[ "${BACKUP_SIMULATE}" == "true" ]] && simulate_seconds="${BACKUP_SIMULATE_SECONDS:-5}"
    local php_ver
    php_ver="$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo unknown)"

    cat > "${manifest}" <<EOF
{
  "timestamp": "$(date -Iseconds 2>/dev/null || date)",
  "backup_dir": "$(basename "${BACKUP_DIR}")",
  "format": "multi-file",
  "mode": "${mode}",
  "simulated": ${simulated},
  "simulate_seconds": ${simulate_seconds},
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "php_version": "${php_ver}",
  "moodle_version": "${MOODLE_VERSION}",
  "moodle_release": "${MOODLE_RELEASE}",
  "wwwroot": "${MOODLE_CFG_wwwroot}",
  "dirroot": "${MOODLE_ROOT}",
  "dataroot": "${MOODLE_CFG_dataroot}",
  "dbhost": "${MOODLE_CFG_dbhost}",
  "dbname": "${MOODLE_CFG_dbname}",
  "dbuser": "${MOODLE_CFG_dbuser}",
  "dbtype": "${MOODLE_CFG_dbtype}",
  "dbprefix": "${MOODLE_CFG_dbprefix}",
  "components": [
    "database.sql.gz",
    "moodlecode.tar.gz",
    "moodledata.tar.gz",
    "contrib-plugins.txt",
    "manifest.json",
    "RESTORE.md"
  ]
}
EOF
    log_info "Manifest written"
}

copy_restore_readme() {
    local dest="${BACKUP_DIR}/RESTORE.md"
    local src="${REMOTE_BIN_DIR}/RESTORE.md"
    local alt="${REMOTE_BIN_DIR}/../restore/RESTORE.md"
    if [[ -f "${src}" ]]; then
        cp "${src}" "${dest}"
    elif [[ -f "${alt}" ]]; then
        cp "${alt}" "${dest}"
    else
        cat > "${dest}" <<'EOF'
# Moodle backup restore

See project README.md and moodle-restore.sh on the backup host.
EOF
    fi
}

backup_total_size() {
    local total=0 f size
    for f in database.sql.gz moodlecode.tar.gz moodledata.tar.gz; do
        if [[ -f "${BACKUP_DIR}/${f}" ]]; then
            size="$(stat -c%s "${BACKUP_DIR}/${f}" 2>/dev/null || stat -f%z "${BACKUP_DIR}/${f}" 2>/dev/null || echo 0)"
            total=$(( total + size ))
        fi
    done
    echo "${total}"
}

finalize_backup() {
    ERROR_STEP="finalize_backup"

    write_contrib_plugins_list
    write_manifest
    copy_restore_readme

    local total elapsed
    total="$(backup_total_size)"
    elapsed=$(( $(date +%s) - BACKUP_START_EPOCH ))
    report_progress "complete" 100 "Backup finished"

    log_info "Backup complete in ${elapsed}s"
    log_info "Backup directory: ${BACKUP_DIR}"
    log_info "Total size: $(human_size "${total}")"
    log_info "Components: database.sql.gz, moodlecode.tar.gz, moodledata.tar.gz, contrib-plugins.txt, manifest.json"
}

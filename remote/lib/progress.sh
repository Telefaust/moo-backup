#!/usr/bin/env bash
# Progress reporting for long-running backup steps.

report_progress() {
    local step="$1"
    local pct="$2"
    local msg="${3:-}"
    log_info "@PROGRESS ${step} ${pct} ${msg}"
}

# GNU tar: 0 ok, 1 files changed during read, 2+ fatal. Keep archive on exit 1.
_tar_accept_exit() {
    local rc="$1"
    local out="$2"
    if [[ ${rc} -eq 0 ]]; then
        return 0
    fi
    if [[ ${rc} -eq 1 && -f "${out}" && -s "${out}" ]]; then
        log_warn "tar exited with 1 (files changed during read); archive kept: $(basename "${out}")"
        return 0
    fi
    return "${rc}"
}

dir_size_bytes() {
    local path="$1"
    du -sb "${path}" 2>/dev/null | awk '{print $1}'
}

file_count_under() {
    local path="$1"
    find "${path}" 2>/dev/null | wc -l | tr -d ' '
}

_monitor_gzip_file() {
    local step="$1"
    local outfile="$2"
    local estimate="$3"
    local watcher_pid="$4"
    local cur pct last_pct=-1

    [[ "${estimate}" -lt 1048576 ]] && estimate=1048576

    while kill -0 "${watcher_pid}" 2>/dev/null; do
        if [[ -f "${outfile}" ]]; then
            cur="$(stat -c%s "${outfile}" 2>/dev/null || stat -f%z "${outfile}" 2>/dev/null || echo 0)"
            pct=$(( cur * 100 / estimate ))
            (( pct > 99 )) && pct=99
            if [[ "${pct}" -ne "${last_pct}" ]]; then
                report_progress "${step}" "${pct}" "Written $(human_size "${cur}")"
                last_pct="${pct}"
            fi
        fi
        sleep 1
    done
}

_run_tar_with_checkpoints() {
    local step="$1"
    local out="$2"
    local parent="$3"
    local name="$4"
    shift 4
    local -a tar_excludes=("$@")
    local src="${parent}/${name}"
    local fcount checkpoint_interval

    fcount="$(file_count_under "${src}")"
    [[ "${fcount}" -lt 1 ]] && fcount=1
    checkpoint_interval=$(( fcount / 100 ))
    [[ "${checkpoint_interval}" -lt 50 ]] && checkpoint_interval=50

    export MOOBACKUP_STEP="${step}"
    export MOOBACKUP_FCOUNT="${fcount}"

    local tar_rc
    set +e
    # shellcheck disable=SC2086
    tar -C "${parent}" "${tar_excludes[@]}" -czf "${out}" "${name}" \
        --warning=no-file-changed \
        --checkpoint="${checkpoint_interval}" \
        --checkpoint-action=exec='bash -c '"'"'
            pct=$(( ${TAR_CHECKPOINT:-0} * 100 / ${MOOBACKUP_FCOUNT:-1} ))
            (( pct > 99 )) && pct=99
            echo "[$(date "+%Y-%m-%d %H:%M:%S")] [INFO] @PROGRESS ${MOOBACKUP_STEP} ${pct} files ${TAR_CHECKPOINT:-0}/${MOOBACKUP_FCOUNT}" 
        '"'"''
    tar_rc=$?
    set -e
    _tar_accept_exit "${tar_rc}" "${out}"
}

_run_tar_with_pv() {
    local step="$1"
    local out="$2"
    local parent="$3"
    local name="$4"
    local total="$5"
    shift 5
    local -a tar_excludes=("$@")
    local fifo reader_pid last_pct=-1 pct line

    fifo="$(mktemp -u)"
    mkfifo "${fifo}"
    (
        while IFS= read -r line; do
            line="${line//$'\r'/}"
            pct="${line%%.*}"
            if [[ "${pct}" =~ ^[0-9]+$ ]] && [[ "${pct}" -ne "${last_pct}" ]]; then
                report_progress "${step}" "${pct}" "Archiving..."
                last_pct="${pct}"
            fi
        done < "${fifo}"
    ) &
    reader_pid=$!

    local tar_rc
    set +e
    # shellcheck disable=SC2086
    tar -C "${parent}" "${tar_excludes[@]}" --warning=no-file-changed -cf - "${name}" 2>/dev/null | \
        pv -f -n -s "${total}" 2>"${fifo}" | gzip > "${out}"
    tar_rc=${PIPESTATUS[0]}
    set -e
    wait "${reader_pid}" 2>/dev/null || true
    rm -f "${fifo}"
    _tar_accept_exit "${tar_rc}" "${out}"
}

run_tar_gzip_progress() {
    local step="$1"
    local out="$2"
    local parent="$3"
    local name="$4"
    shift 4
    local -a tar_excludes=("$@")
    local src="${parent}/${name}"
    local total est_compressed tar_pid

    total="$(dir_size_bytes "${src}")"
    report_progress "${step}" 0 "Starting source $(human_size "${total}")"

    if command -v pv >/dev/null 2>&1 && [[ "${total}" -gt 0 ]]; then
        _run_tar_with_pv "${step}" "${out}" "${parent}" "${name}" "${total}" "${tar_excludes[@]}"
    else
        _run_tar_with_checkpoints "${step}" "${out}" "${parent}" "${name}" "${tar_excludes[@]}"
    fi

    report_progress "${step}" 100 "Complete ($(human_size "$(stat -c%s "${out}" 2>/dev/null || stat -f%z "${out}" 2>/dev/null || echo 0)"))"
}

run_dump_gzip_progress() {
    local step="$1"
    local out="$2"
    local dump_cmd="$3"
    local defaults_file="$4"
    local dbname="$5"
    local est_bytes="$6"
    local est_compressed dump_pid fifo reader_pid last_pct=-1 pct line

    report_progress "${step}" 0 "Dumping database ${dbname}..."

    if command -v pv >/dev/null 2>&1 && [[ "${est_bytes}" -gt 0 ]]; then
        fifo="$(mktemp -u)"
        mkfifo "${fifo}"
        (
            while IFS= read -r line; do
                line="${line//$'\r'/}"
                pct="${line%%.*}"
                if [[ "${pct}" =~ ^[0-9]+$ ]] && [[ "${pct}" -ne "${last_pct}" ]]; then
                    report_progress "${step}" "${pct}" "Dumping..."
                    last_pct="${pct}"
                fi
            done < "${fifo}"
        ) &
        reader_pid=$!

        "${dump_cmd}" \
            --defaults-extra-file="${defaults_file}" \
            --single-transaction \
            --routines \
            --triggers \
            --quick \
            --default-character-set=utf8mb4 \
            "${dbname}" 2>/dev/null | \
            pv -f -n -s "${est_bytes}" 2>"${fifo}" | gzip > "${out}"
        wait "${reader_pid}" 2>/dev/null || true
        rm -f "${fifo}"
    else
        est_compressed=$(( est_bytes / 3 ))
        [[ "${est_compressed}" -lt 1048576 ]] && est_compressed=1048576
        (
            "${dump_cmd}" \
                --defaults-extra-file="${defaults_file}" \
                --single-transaction \
                --routines \
                --triggers \
                --quick \
                --default-character-set=utf8mb4 \
                "${dbname}" | gzip > "${out}"
        ) &
        dump_pid=$!
        _monitor_gzip_file "${step}" "${out}" "${est_compressed}" "${dump_pid}"
        wait "${dump_pid}"
    fi
}

estimate_database_bytes() {
    local client="$1"
    local defaults_file="$2"
    local dbname="$3"
    local raw

    raw="$("${client}" --defaults-extra-file="${defaults_file}" -N -e \
        "SELECT COALESCE(SUM(data_length + index_length), 0)
         FROM information_schema.tables
         WHERE table_schema = '${dbname}'" 2>/dev/null || echo 0)"
    raw="${raw//[^0-9]/}"
    [[ -z "${raw}" ]] && raw=0
    echo $(( raw * 110 / 100 ))
}

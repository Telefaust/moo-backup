#!/usr/bin/env bash
# Moodle maintenance mode control.

MAINTENANCE_FILE=""
MAINTENANCE_SKIPPED=false

_maintenance_html() {
    cat <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Maintenance | Техническое обслуживание</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #eef1f6;
    --card: #ffffff;
    --text: #1a2332;
    --muted: #5c6778;
    --accent: #2563eb;
    --border: #d8dee9;
    --shadow: 0 12px 40px rgba(15, 23, 42, 0.08);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0f1419;
      --card: #1a222d;
      --text: #e8edf4;
      --muted: #9aa7b8;
      --accent: #60a5fa;
      --border: #2d3748;
      --shadow: 0 12px 40px rgba(0, 0, 0, 0.35);
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1.5rem;
    font-family: "Segoe UI", system-ui, -apple-system, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.55;
  }
  .panel {
    width: 100%;
    max-width: 32rem;
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 1rem;
    box-shadow: var(--shadow);
    overflow: hidden;
  }
  .header {
    padding: 1.25rem 1.5rem 1rem;
    border-bottom: 1px solid var(--border);
    background: linear-gradient(180deg, rgba(37, 99, 235, 0.08), transparent);
  }
  .badge {
    display: inline-block;
    margin-bottom: 0.75rem;
    padding: 0.25rem 0.65rem;
    border-radius: 999px;
    font-size: 0.75rem;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--accent);
    background: rgba(37, 99, 235, 0.12);
  }
  .header h1 {
    margin: 0 0 0.35rem;
    font-size: 1.35rem;
    font-weight: 650;
    line-height: 1.3;
  }
  .header .subtitle {
    margin: 0;
    font-size: 1.05rem;
    color: var(--muted);
    font-weight: 500;
  }
  .content { padding: 1.25rem 1.5rem 1.5rem; }
  .block + .block {
    margin-top: 1.15rem;
    padding-top: 1.15rem;
    border-top: 1px solid var(--border);
  }
  .lang {
    display: block;
    margin-bottom: 0.35rem;
    font-size: 0.7rem;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--accent);
  }
  .block p {
    margin: 0;
    font-size: 0.98rem;
    color: var(--text);
  }
  .hint {
    margin: 1.15rem 0 0;
    font-size: 0.85rem;
    color: var(--muted);
    text-align: center;
  }
</style>
</head>
<body>
  <main class="panel" role="main">
    <header class="header">
      <span class="badge">Maintenance</span>
      <h1>Site under maintenance</h1>
      <p class="subtitle">Сайт на техническом обслуживании</p>
    </header>
    <div class="content">
      <section class="block" lang="en">
        <span class="lang">English</span>
        <p>The site is temporarily unavailable while a backup is in progress. Please try again in a few minutes.</p>
      </section>
      <section class="block" lang="ru">
        <span class="lang">Русский</span>
        <p>Сайт временно недоступен: выполняется резервное копирование. Пожалуйста, зайдите через несколько минут.</p>
      </section>
      <p class="hint">Thank you for your patience · Спасибо за понимание</p>
    </div>
  </main>
</body>
</html>
EOF
}

enable_maintenance() {
    ERROR_STEP="enable_maintenance"
    MAINTENANCE_FILE="${MOODLE_CFG_dataroot}/climaintenance.html"

    if [[ -w "${MOODLE_CFG_dataroot}" ]]; then
        log_info "Enabling maintenance mode (climaintenance.html)..."
        _maintenance_html > "${MAINTENANCE_FILE}"
        MAINTENANCE_ENABLED=true
        log_info "Maintenance mode enabled"
        if declare -F remove_backup_notice >/dev/null; then
            remove_backup_notice || true
        fi
        return 0
    fi

    log_info "Trying Moodle CLI for maintenance mode..."
    if php "${MOODLE_ROOT}/admin/cli/maintenance.php" --enable 2>/dev/null; then
        MAINTENANCE_ENABLED=true
        MAINTENANCE_FILE="${MOODLE_CFG_dataroot}/climaintenance.html"
        log_info "Maintenance mode enabled via CLI"
        if declare -F remove_backup_notice >/dev/null; then
            remove_backup_notice || true
        fi
        return 0
    fi

    log_warn "Maintenance mode skipped: no write access to dataroot (${MOODLE_CFG_dataroot})"
    log_warn "Backup will continue without maintenance mode"
    _permissions_reminder "${MOODLE_CFG_dataroot}"
    MAINTENANCE_SKIPPED=true
}

disable_maintenance() {
    if [[ "${MAINTENANCE_SKIPPED}" == "true" ]]; then
        return 0
    fi

    if [[ "${MAINTENANCE_ENABLED}" != "true" ]]; then
        return 0
    fi

    log_info "Disabling maintenance mode..."

    if [[ -f "${MAINTENANCE_FILE}" ]] && [[ -w "${MOODLE_CFG_dataroot}" || -w "${MAINTENANCE_FILE}" ]]; then
        rm -f "${MAINTENANCE_FILE}"
        MAINTENANCE_ENABLED=false
        log_info "Maintenance mode disabled"
        return 0
    fi

    if php "${MOODLE_ROOT}/admin/cli/maintenance.php" --disable 2>/dev/null; then
        MAINTENANCE_ENABLED=false
        log_info "Maintenance mode disabled via CLI"
        return 0
    fi

    ERROR_STEP="disable_maintenance"
    log_error "Failed to disable maintenance mode — remove ${MAINTENANCE_FILE} manually if present"
    return 1
}

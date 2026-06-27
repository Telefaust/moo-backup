# Moo-backup — Project Guide

Moodle backup system: bash scripts on Linux host + Windows GUI (tkinter/paramiko) + 2 Moodle plugins.
Full technical context and roadmap: [PLAN.md](PLAN.md).

---

## Running the GUI (dev)

```batch
run-gui.bat
```

Or directly: `.venv\Scripts\python.exe gui/main.py`

First run without `gui/profiles.json` opens the Connections dialog automatically.

---

## Project Structure

| Path | Purpose |
|------|---------|
| `gui/main.py` | Entry point → `gui/ui/app.py` |
| `gui/ui/app.py` | Main window (tkinter) |
| `gui/ssh_client.py` | SSH via paramiko; parses stdout markers |
| `gui/profiles.py` | Connection profiles (SSH, paths) |
| `gui/paths.py` | `app_root()` / `gui_dir()` — dev vs frozen (PyInstaller) |
| `remote/moodle-backup.sh` | Main bash entry point on Linux host |
| `remote/lib/` | Bash library modules |
| `remote/lib/quiz_backup.php` | Moodle API CLI — **GPL v3 exception** |
| `remote/lib/parse_config.php` | Reads config.php as text — MIT |
| `moodle-plugin/local/backupnotice/` | Site banner plugin (v1.0.2) |
| `moodle-plugin/quizaccess/backupnotice/` | Quiz access rule plugin |
| `restore/moodle-restore.sh` | Restore script (not live-tested yet) |
| `build-gui.ps1` | PyInstaller build → `dist\Moo-backup-portable.zip` |
| `moodle-plugin/build-zip.py` | Plugin ZIPs → `moodle-plugin/dist/` |

---

## SSH stdout markers (parsed by `ssh_client.py`)

| Marker | Meaning |
|--------|---------|
| `@BACKUP_DIR path` | Backup directory created |
| `@PROGRESS step pct msg` | Progress bar update |
| `@QUIZ_ATTEMPTS {json}` | Quiz attempts table |
| `@BACKUP_WAIT start\|poll\|done\|timeout …` | Wait phase; Force/Cancel in GUI |

---

## Backup flow

1. `load_env` → `init_backup_dirs` → `@BACKUP_DIR`
2. `load_moodle_config` via `parse_config.php`
3. Quiz prep (unless `--no-quiz-prep`): verify runner → list → banner → wait for open attempts
4. Maintenance ON → remove banner
5. DB dump + code archive + moodledata tar
6. Maintenance OFF

`--simulate` skips real dump/tar, uses `sleep N` instead. Quiz and maintenance flow unchanged.

---

## Licensing

| File / Scope | License |
|---|---|
| Root `LICENSE` | MIT — applies to most of the project |
| `moodle-plugin/LICENSE.txt` | GPL v3 — applies to plugin files |
| `remote/lib/quiz_backup.php` | GPL v3 (Moodle bootstrap — explicit file exception) |
| `THIRD_PARTY_LICENSES.txt` | Bundled dependencies (paramiko LGPL-2.1, etc.) |

Copyright: `Andrey "Telefaust" Bogachev`

---

## Rules

### Always on changes
- Update `**Последнее обновление:**` in **README.md** and **PLAN.md** in the same commit

### Never commit
- `gui/profiles.json` — SSH credentials, in `.gitignore`
- `gui/keys/` — SSH private keys, in `.gitignore`

### Never commit to `dist/` or `build/`
Both are in `.gitignore`; contain absolute paths from build machine.

---

## Build (Windows portable ZIP)

```powershell
.\build-gui.ps1
```

Output: `dist\Moo-backup-portable.zip`
Also builds plugin ZIPs via `moodle-plugin\build-zip.py` → `moodle-plugin\dist\*.zip`

Before each release: smoke-test the ZIP on a machine without Python (see Roadmap in PLAN.md).

---

## Deployment (on host)

1. GUI → **Connect** → **Deploy scripts** (uploads `remote/` + `restore/` to `~/moobackup/bin/`)
2. First time on new host: `setup-moodledata-acl.sh --check-only --moodle-root …`
3. Test: `moodle-backup.sh --simulate` with an active quiz attempt

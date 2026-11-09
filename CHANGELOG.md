# Changelog

Формат: [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версионирование: [SemVer](https://semver.org/lang/ru/).

Версия проекта (GUI, скрипты `remote/` и `restore/`) хранится в файле [`VERSION`](VERSION).
Плагины Moodle версионируются отдельно (`moodle-plugin/*/version.php`):
`local_backupnotice` 1.0.2, `quizaccess_backupnotice` 1.0.0.

## [Unreleased]

## [1.0.1] — 2026-11-09

### Added
- Версионирование проекта: файл `VERSION`, `CHANGELOG.md`, `gui/version.py`.
- Версия в заголовке окна GUI.
- Поле `moo_backup_version` в `manifest.json` и строка версии в логе бэкапа.
- Версия в имени portable-архива: `Moo-backup-portable-<версия>.zip`.

### Fixed
- `build-gui.ps1`: сборка падала, т.к. искала `moodle-plugin\LICENSE` вместо `LICENSE.txt`.

## [1.0.0] — 2026-06-28

### Added
- Первый публичный релиз.
- Bash-скрипты бэкапа на Linux-хосте: multi-file бэкап (БД, код, moodledata, manifest), maintenance-режим, POSIX ACL.
- Quiz-aware flow: ожидание открытых попыток, баннер, Force/Cancel.
- Windows GUI (tkinter/paramiko): профили подключений, таблица попыток, Simulate, индикатор прогресса, deploy скриптов.
- Скрипт восстановления `restore/moodle-restore.sh` (live-тест не проводился).
- Плагины Moodle `local_backupnotice` и `quizaccess_backupnotice`.
- Portable-сборка для Windows (PyInstaller).

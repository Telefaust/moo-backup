# Moo-backup

Система резервного копирования сайта на Moodle: bash-скрипты на Linux-хосте и GUI под Windows.

**Последнее обновление:** 24 июня 2026

---

**Предупреждение**: проект разрабатывается с активным участием AI ассистентов. Код и функциональность проверяются разработчиком. Багрепорты приветствуются.

---

## Структура проекта

| Каталог / файл      | Назначение                                                                     |
| ------------------- | ------------------------------------------------------------------------------ |
| `remote/`           | Скрипты бэкапа на Linux-хосте                                                  |
| `restore/`          | Скрипт и инструкция восстановления                                             |
| `gui/`              | Windows GUI (Python + tkinter)                                                 |
| `moodle-plugin/`    | `local_backupnotice` (баннер) + `quizaccess_backupnotice` (блок новых попыток) |
| `gui/profiles.json` | Подключения и секреты (создаётся GUI)                                          |
| `gui/keys/`         | SSH-ключи (по одному на профиль)                                               |
| `run-gui.bat`       | Запуск GUI под Windows (с проверкой venv и зависимостей)                       |
| `build-gui.ps1`     | Сборка portable ZIP (`dist/Moo-backup-portable.zip`)                           |

---

## Portable ZIP (Windows, без Python)

На машине **разработчика** (Python 3.10+), должен быть построен venv (через `run-gui.bat` или вручную):

```powershell
.\build-gui.ps1
```

Результат:

- `dist\Moo-backup\` — распаковываемая папка (`Moo-backup.exe`, `_internal\`, `remote\`, `restore\`, `moodle-plugin\`, `gui\`)
- `dist\Moo-backup-portable.zip` — архив для передачи на prod-рабочую станцию

На целевой Windows-машине: распаковать ZIP в любой каталог, запустить `Moo-backup.exe`. При **первом запуске** (нет `gui/profiles.json`) сразу открывается окно **Connections** — создайте профиль и нажмите **Save**. Плагины Moodle — из `moodle-plugin\dist\*.zip` (см. `moodle-plugin\README.md`).

Обновление только bash-скриптов: заменить папку `remote\` из новой сборки → **Deploy scripts** в GUI (замена exe не обязательна).

---

## Быстрый старт (Windows)

1. Запустите **`run-gui.bat`** (двойной щелчок) или вручную:

```powershell
cd Moo-backup
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
python gui/main.py
```

2. В окне **Connections…** создайте подключение: SSH host/login/password, пути Moodle и архива.  
   При первом запуске portable/exe окно **Connections** открывается автоматически.
3. **Connect** → **Deploy scripts**.
4. На хосте (один раз): права на dataroot и CLI bootstrap — см. [Настройка хоста](#настройка-хоста-linux) (`--check-only` или ACL).
5. Установите плагины `local_backupnotice` (баннер) и **`quizaccess_backupnotice`** (блок новых попыток quiz во время ожидания).
6. **Run Backup** (для отладки процесса - чекбокс **Simulate backup**).

---

## Настройка подключений (GUI)

Все параметры Windows-GUI хранятся в **`gui/profiles.json`**.

- Несколько подключений, переключение в **Connection**.
- Шаблон: `gui/profiles.json.example`.
- Если вы форкнули проект - **не коммитьте** `profiles.json` и `gui/keys/`.

| Поле                        | Описание                                            |
| --------------------------- | --------------------------------------------------- |
| Display name                | Имя в списке                                        |
| SSH host / login / password | Доступ к хосту бэкапа                               |
| Site URL (FQDN)             | URL Moodle (справочно)                              |
| Moodle path on host         | Каталог кода Moodle (`BACKUPER_LOCATION`)           |
| Remote storage path         | Каталог бэкапов на хосте                            |
| Local archive (Windows)     | Локальное хранилище скачанных бэкапов               |
| Remote scripts dir          | Каталог скриптов на хосте, обычно `~/moobackup/bin` |

---

## SSH-ключи

В **Connections… → SSH key**: Generate / Delete / Copy public key / Activate / Deactivate on host. Логика работы: создается соединение с логином и паролем, генерируется ключ, активируется на хосте, после чего соединение становится возможно по ключу.

GUI подключается **сначала по ключу**, при неудаче — по паролю. В статусной строке внизу окна: `Connected ok (key)` или `(password)`; слева — профиль, host, пути storage/archive.

---

## GUI: основные действия

Для получения корректного бэкапа moodle должен быть переведен в maintenance mode, что прервет попытки сдачи квизов (тестов, экзаменов) для тех, кому не повезло сдавать именно в эту минуту. Во избежание такого сценария система проверяет, есть ли активные (открытые) попытки сдачи квизов и дожидается их завершения, блокируя в это время начало новых попыток с помощью плагина `quizaccess_backupnotice`. С помощью плагина `local_backupnotice` всем пользователям портала при этом выводится информационная строка об ожидании начала бэкапа с прогнозом времени до его начала, вычисленным на основе таймаутов квизов. С помощью кнопок Force / Cancel backup админ может отменить бэкап либо выполнить его немедленно, не дожидаясь завершения попыток сдачи.

| Элемент                               | Действие                                                                       |
| ------------------------------------- | ------------------------------------------------------------------------------ |
| Run Backup / Restore / Deploy scripts | Бэкап, восстановление, выкладка скриптов                                       |
| Force backup / Cancel backup          | Во время ожидания quiz: форсировать или отменить (файл `control` на хосте)     |
| Full moodledata                       | `--full` — dataroot без исключений                                             |
| Simulate backup                       | Quiz + maintenance без архивов; задержка в GUI (**Delay (s)**, по умолчанию 5) |
| Open quiz attempts                    | Таблица активных попыток; обновление из лога и poll 30 с в фазе ожидания       |
| Remote / Local lists                  | Списки бэкапов; Download / Upload / Delete / View log                          |

Прогресс и quiz-данные приходят из маркеров stdout: `@PROGRESS`, `@QUIZ_ATTEMPTS`, `@BACKUP_WAIT`, `@BACKUP_DIR`.

---

## Настройка хоста (Linux)

### 1. Права на dataroot и CLI bootstrap

Пользователь бэкапа: **read** на moodledata, **write** в корень dataroot (maintenance + баннер), **write** на каталоги CLI bootstrap Moodle (`temp`, `cache`, `localcache`, `muc` — пути из `config.php` или дефолты относительно dataroot).

**Проверка** (от пользователя бэкапа, ACL на ФС не требуется):

```bash
~/moobackup/bin/setup-moodledata-acl.sh --check-only --moodle-root /var/www/moodle
# --user необязателен: по умолчанию текущий пользователь
# или: --dataroot /data/moodata
```

`--check-only` проверяет **фактические права** (read/traverse dataroot, запись в корень, bootstrap-каталоги, `quiz_backup.php list`). Подходит для сетевого dataroot без POSIX ACL.

**Настройка через ACL** (один раз, root; локальный том с пакетом `acl`):

```bash
sudo ~/moobackup/bin/setup-moodledata-acl.sh --user scripter --moodle-root /var/www/moodle
```

Просмотр списка bootstrap-каталогов:

```bash
php ~/moobackup/bin/lib/parse_config.php /var/www/moodle --bootstrap-dirs
```

### 2. Quiz: `quiz_backup.php`

После ACL из п.1 `quiz_backup.php` запускается **от пользователя бэкапа** (например `scripter`) без sudo.

**Проверка:**

```bash
php ~/moobackup/bin/lib/quiz_backup.php list --moodle-root=/var/www/moodle
```

Если `php` не `/usr/bin/php`, укажите в `moodle-backup.env`:

```bash
MOOBACKUP_QUIZ_PHP=/usr/bin/php8.2
```

**Ручной вызов (обёртка с загрузкой env):**

```bash
~/moobackup/bin/lib/run_quiz_php.sh /var/www/moodle list
```

### 3. `moodle-backup.env`

Файл `~/moobackup/bin/moodle-backup.env` (создаётся при **Deploy scripts**):

```bash
BACKUPER_LOCATION=/var/www/moodle
BACKUPER_STORAGE_PATH=/home/scripter/moobackup
# MOOBACKUP_QUIZ_PHP=/usr/bin/php
```

---

## Запуск на хосте без GUI

```bash
~/moobackup/bin/moodle-backup.sh
~/moobackup/bin/moodle-backup.sh --full
~/moobackup/bin/moodle-backup.sh --simulate --simulate-seconds 30
~/moobackup/bin/moodle-backup.sh --force       # не ждать quiz-попытки
~/moobackup/bin/moodle-backup.sh --no-quiz-prep # без quiz/banner (классический flow)
```

Cron:

```cron
0 2 * * * /home/scripter/moobackup/bin/moodle-backup.sh >> /home/scripter/moobackup/cron.log 2>&1
```

---

## Состав бэкапа

Каталог `<remote storage>/YYYY-MM-DD_HH-MM-SS/` (multi-file; отдельные компоненты, не один общий архив):

| Файл                              | Описание                                                             |
| --------------------------------- | -------------------------------------------------------------------- |
| `database.sql.gz`                 | Дамп MariaDB/MySQL                                                   |
| `moodlecode.tar.gz`               | Код Moodle                                                           |
| `moodledata.tar.gz`               | Dataroot (с исключениями или `--full`)                               |
| `contrib-plugins.txt`             | Список сторонних плагинов (может понадобиться при disaster recovery) |
| `manifest.json`                   | Метаданные (`simulated: true` при `--simulate`)                      |
| `RESTORE.md`                      | Краткая инструкция restore                                           |
| `backup.log` / `backup.error.log` | Журналы                                                              |
| `control`                         | Временно: `force` / `cancel` во время ожидания quiz                  |

### Порядок бэкапа (quiz-aware, по умолчанию)

1. Проверка quiz runner и **`quizaccess_backupnotice` обязателен** (`env-check`).
2. Список открытых попыток.
3. Записать `backup-notice.json` (`block_new_quiz_attempts: true`) — блокировка новых попыток на всех quiz.
4. Ждать `inprogress`/`overdue` (poll 30 с). Активные попытки продолжаются; новые блокирует `quizaccess_backupnotice`.
5. **Maintenance ON** → удалить `backup-notice.json` (страница maintenance — двуязычная EN+RU в `climaintenance.html`).
6. Архивация: БД → code → moodledata → finalize (или пауза при `--simulate`, по умолчанию 5 с).
7. **Maintenance OFF**.

### Флаги CLI

| Флаг                   | Эффект                                                                 |
| ---------------------- | ---------------------------------------------------------------------- |
| `--full`               | Полный moodledata                                                      |
| `--simulate`           | Шаги 1–5 как обычно; вместо архивов — пауза (см. `--simulate-seconds`) |
| `--simulate-seconds N` | Длительность паузы в simulate (по умолчанию **5**)                     |
| `--force`              | Не ждать quiz-попытки (шаг 4)                                          |
| `--no-quiz-prep`       | Пропустить шаги 1–4 и баннер                                           |

### Moodle-плагины (баннер + блок новых попыток quiz)

**`local_backupnotice`** — site-wide баннер, пока есть `backup-notice.json`.  
Текст по умолчанию (EN+RU, одна строка): `Backup soon / finish tests · Скоро бэкап / завершите тесты · MM:SS` (таймер без подписи).  
Установка: ZIP **`local_backupnotice_moodle40-2026061102.zip`** (v1.0.2) из `moodle-plugin/dist/` (см. [moodle-plugin/README.md](moodle-plugin/README.md)).

**`quizaccess_backupnotice`** — правило доступа к quiz: **`prevent_new_attempt()`** пока активен бэкап (файл в dataroot). Не трогает уже начатые попытки (`prevent_access` не переопределён).  
ZIP: `moodle-plugin/dist/quizaccess_backupnotice_moodle40-*.zip`.  
Тип при установке: **Quiz access rule**, папка **`backupnotice`** → путь `mod/quiz/accessrule/backupnotice/`.

Проверка:

```bash
php ~/moobackup/bin/lib/quiz_backup.php env-check --moodle-root=/var/www/moodle
# "quizaccess_backupnotice_installed": true
```

Баннер и блок новых попыток снимаются при включении maintenance (шаг 5).

---

## Восстановление

См. [restore/RESTORE.md](restore/RESTORE.md). Restore в GUI — под отдельными credentials с write в webroot/dataroot.

При отмене через GUI/Cancel (exit 5) снимается `backup-notice.json` (автоматически).

---

## Exit codes

| Код | Значение                                                 |
| --- | -------------------------------------------------------- |
| 0   | Успех                                                    |
| 1   | Конфигурация                                             |
| 3   | БД                                                       |
| 4   | Архивация                                                |
| 5   | Отмена оператором во время ожидания quiz                 |
| 6   | Quiz prep (ACL CLI bootstrap, `quiz_backup.php`, плагин) |

---

## Troubleshooting

| Симптом                                     | Решение                                                                             |
| ------------------------------------------- | ----------------------------------------------------------------------------------- |
| Первый запуск GUI: нет окна / сразу выход   | Обновить exe из последней сборки; должно открыться **Connections**                  |
| Maintenance mode skipped                    | Права write в корень dataroot: `--check-only` или `sudo setup-moodledata-acl.sh …`  |
| `--check-only` падает на ACL                | Обновить `setup-moodledata-acl.sh` (Deploy); в check-only ACL не обязателен         |
| quiz_backup.php list failed                 | `--check-only --moodle-root …`; write на temp/cache/localcache/muc                  |
| Open quiz attempts: 0 (есть попытки)        | Deploy; смотреть лог на `[ERROR] quiz`                                              |
| Backup exit 5                               | Отменён в фазе ожидания quiz                                                        |
| Backup exit 6                               | Quiz runner: `setup-moodledata-acl.sh --moodle-root`; `quizaccess_backupnotice`     |
| Quiz list OK вручную, в бэкапе нет          | Deploy последней версии `quiz.sh` (capture stdout + `/usr/bin/php`)                 |
| Backup exit 6, quizaccess not installed     | Установить `quizaccess_backupnotice` (обязателен для quiz-prep)                     |
| Новые попытки quiz во время ожидания бэкапа | `quizaccess_backupnotice` + Deploy `backup_notice.sh`                               |
| Failed to list contrib plugins              | **Deploy scripts**; проверить `quiz_backup.php contrib-list` от пользователя бэкапа |

---

## Зависимости

- **Windows GUI:** Python 3.10+, tkinter, paramiko
- **Linux host:** php, tar, gzip, mysqldump; пакет **acl** (только для `setup-moodledata-acl.sh` без `--check-only`); опционально `pv`
- **Quiz helper:** Moodle 4.x/5.x, write CLI bootstrap; **`quizaccess_backupnotice`** (обязателен); баннер **`local_backupnotice` v1.0.2+** (опционален, рекомендуется)

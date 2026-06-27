# Восстановление Moodle из бэкапа Moo-backup

## Содержимое бэкапа

Каталог `YYYY-MM-DD_HH-MM-SS/` с отдельными файлами:

- `database.sql.gz` — дамп MariaDB/MySQL
- `moodlecode.tar.gz` — полный код Moodle (включая vendor, node_modules при наличии)
- `moodledata.tar.gz` — каталог данных
- `manifest.json` — метаданные (пути, версия, БД без пароля)

## Требования

- Linux с Apache, MariaDB/MySQL, PHP (версия совместима с Moodle из бэкапа)
- Учётная запись с **read+write** на целевой webroot и moodledata
- Права на импорт в БД (CREATE DATABASE при `--db-create`)

## Запуск

```bash
~/moobackup/bin/moodle-restore.sh \
  --archive /home/scripter/moobackup/2026-06-11_02-00-00/ \
  --webroot /var/www/moodle \
  --dataroot /var/moodledata \
  --db-host localhost \
  --db-name moodle \
  --db-user moodle \
  --db-pass 'secret' \
  --db-create
```

Пути по умолчанию берутся из `manifest.json` в каталоге бэкапа.

Проверка прав без изменений:

```bash
moodle-restore.sh --archive PATH --dry-run
```

## Смена URL

```bash
moodle-restore.sh --archive PATH \
  --replace-url 'https://old.example.com' \
  --replace-with 'https://new.example.com'
```

## После восстановления

1. Настроить виртуальный хост Apache на webroot
2. Проверить права: `www-data` должен писать в moodledata
3. Отключить maintenance mode при необходимости: `php admin/cli/maintenance.php --disable`

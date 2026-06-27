# local_backupnotice — баннер перед бэкапом Moodle

Плагин для [Moo-backup](../../../README.md): показывает **site-wide баннер**, пока в dataroot существует файл `backup-notice.json`. Скрипт бэкапа создаёт файл перед ожиданием завершения тестов и **удаляет его сразу после включения maintenance mode**.

**Moodle:** 4.0+

**Архив для установки:** [`../../dist/local_backupnotice_moodle40-2026061102.zip`](../../dist/local_backupnotice_moodle40-2026061102.zip) (v1.0.2)

**Пересборка ZIP** (обязательно используйте её, не `Compress-Archive` вручную):

```bash
cd moodle-plugin
python build-zip.py          # Windows / Linux
# или: ./build-zip.ps1 / ./build-zip.sh
```

ZIP собирается с **прямыми слэшами** (`backupnotice/version.php`) — так требует Moodle на Linux. Архивы, созданные штатным «Сжать в ZIP» Windows, часто дают `core_plugin/corrupted_archive_structure`.

---

## Установка

В корне архива один каталог `backupnotice/` с `version.php` (компонент `local_backupnotice`).

### Способ A — через админку Moodle

1. Войдите как администратор.
2. **Site administration → Plugins → Install plugins**.
3. Загрузите **`local_backupnotice_moodle40-2026061100.zip`** из `moodle-plugin/dist/` (пересобранный `build-zip.py`).
4. Если Moodle спросит тип вручную (**Show more**):
   - **Plugin type:** Local plugin (`local`)
   - **Plugin name / folder:** `backupnotice`
5. Подтвердите установку.
6. **Site administration → Notifications** → обновление БД.
7. **Purge all caches** или `php admin/cli/purge_caches.php`.

### Способ B — вручную на сервере (если ZIP через UI не ставится)

```bash
MOODLE_ROOT=/var/www/moodle
ZIP=/path/to/local_backupnotice_moodle40-2026061100.zip

unzip -q "${ZIP}" -d /tmp/local_backupnotice-install
install -d -m 755 "${MOODLE_ROOT}/local/backupnotice"
cp -a /tmp/local_backupnotice-install/backupnotice/. "${MOODLE_ROOT}/local/backupnotice/"
chown -R www-data:www-data "${MOODLE_ROOT}/local/backupnotice"
rm -rf /tmp/local_backupnotice-install

cd "${MOODLE_ROOT}"
sudo -u www-data php admin/cli/upgrade.php --non-interactive
sudo -u www-data php admin/cli/purge_caches.php
```

### Настройки

**Site administration → Plugins → Local plugins → Backup notice banner**

| Параметр | Рекомендация |
|----------|----------------|
| Enable banner | Включено |
| Show to guests | Обычно выкл. |
| Default banner message | Текст, если в JSON нет `message` |

Пользователь бэкапа должен иметь write в dataroot для `backup-notice.json` (как для `climaintenance.html`).

---

## Формат backup-notice.json

Файл в **корне dataroot**:

```json
{
  "message": "В ближайшее время начнётся резервное копирование. Завершите начатые тесты.",
  "maintenance_at": "2026-06-12T02:30:00+03:00",
  "poll_seconds": 60,
  "block_new_quiz_attempts": true
}
```

Поле `block_new_quiz_attempts` использует плагин **`quizaccess_backupnotice`** (отдельный ZIP в `moodle-plugin/dist/`). Без него баннер показывается, но новые попытки quiz на «открытых» тестах не блокируются API Moodle.

---

## quizaccess_backupnotice

Устанавливается в **`mod/quiz/accessrule/backupnotice/`**. Блокирует только **новые** попытки, пока существует `backup-notice.json`. Активные попытки не затрагиваются.

```bash
cd moodle-plugin && python build-zip.py
# dist/quizaccess_backupnotice_moodle40-*.zip
```

Проверка с хоста бэкапа:

```bash
php ~/moobackup/bin/lib/quiz_backup.php env-check --moodle-root=/var/www/moodle
```

---

## Интеграция с Moo-backup

`write_backup_notice` / `remove_backup_notice` в `remote/lib/backup_notice.sh`. JSON удаляется автоматически сразу после `enable_maintenance`.

---

## Устранение неполадок

| Симптом | Решение |
|---------|---------|
| **`core_plugin/corrupted_archive_structure`** | Возьмите ZIP из `moodle-plugin/dist/` после `python build-zip.py`. Не используйте архив, собранный проводником Windows. Если ошибка остаётся — **способ B** (ручная распаковка). В сообщении об ошибке Moodle часто указан проблемный путь — пришлите его, если нужна диагностика. |
| **Unable to detect plugin type** | Тип: **Local**, папка: **backupnotice** |
| **Could not create directory** | Права write у веб-сервера на `${MOODLE_ROOT}/local/` |
| Баннер не появляется | Плагин включён? `backup-notice.json` readable для www-data? |
| **`Cannot require a CSS file after <head> has been printed`** | Обновите до **v1.0.1** (inline CSS, без `$PAGE->requires->css` в body hook) |
| Баннер не исчезает | JSON удалён? Purge caches |

---

## Лицензия

GPL v3 or later (как Moodle).

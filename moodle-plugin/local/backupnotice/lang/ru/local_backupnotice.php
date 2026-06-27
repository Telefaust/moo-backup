<?php
// This file is part of Moodle - http://moodle.org/

defined('MOODLE_INTERNAL') || die();

$string['pluginname'] = 'Баннер предупреждения о бэкапе';
$string['privacy:metadata'] = 'Плагин не хранит персональные данные. Он читает временный JSON-файл в dataroot, создаваемый скриптом бэкапа.';

$string['enabled'] = 'Включить баннер';
$string['enabled_desc'] = 'Показывать баннер на всех страницах, пока в dataroot есть файл backup-notice.json.';
$string['showguests'] = 'Показывать гостям';
$string['showguests_desc'] = 'Если включено, гости тоже видят баннер при наличии файла предупреждения.';
$string['defaultmessage'] = 'Текст баннера по умолчанию';
$string['defaultmessage_desc'] = 'Используется, если в backup-notice.json нет поля message.';

$string['default_notice'] = 'Backup soon / finish tests · Скоро бэкап / завершите тесты';

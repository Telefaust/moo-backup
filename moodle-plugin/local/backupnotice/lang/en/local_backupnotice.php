<?php
// This file is part of Moodle - http://moodle.org/

defined('MOODLE_INTERNAL') || die();

$string['pluginname'] = 'Backup notice banner';
$string['privacy:metadata'] = 'The backup notice plugin does not store personal data. It reads a temporary JSON file in dataroot written by the backup script.';

$string['enabled'] = 'Enable banner';
$string['enabled_desc'] = 'Show a site-wide banner while backup-notice.json exists in dataroot.';
$string['showguests'] = 'Show to guests';
$string['showguests_desc'] = 'If enabled, guests also see the banner when the notice file is present.';
$string['defaultmessage'] = 'Default banner message';
$string['defaultmessage_desc'] = 'Used when backup-notice.json has no message field.';

$string['default_notice'] = 'Backup soon / finish tests · Скоро бэкап / завершите тесты';

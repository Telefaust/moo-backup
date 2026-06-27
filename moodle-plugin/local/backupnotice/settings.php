<?php
// This file is part of Moodle - http://moodle.org/

defined('MOODLE_INTERNAL') || die();

if ($hassiteconfig) {
    $settings = new admin_settingpage('local_backupnotice', get_string('pluginname', 'local_backupnotice'));

    $settings->add(new admin_setting_configcheckbox(
        'local_backupnotice/enabled',
        get_string('enabled', 'local_backupnotice'),
        get_string('enabled_desc', 'local_backupnotice'),
        1
    ));

    $settings->add(new admin_setting_configcheckbox(
        'local_backupnotice/showguests',
        get_string('showguests', 'local_backupnotice'),
        get_string('showguests_desc', 'local_backupnotice'),
        0
    ));

    $settings->add(new admin_setting_configtextarea(
        'local_backupnotice/defaultmessage',
        get_string('defaultmessage', 'local_backupnotice'),
        get_string('defaultmessage_desc', 'local_backupnotice'),
        get_string('default_notice', 'local_backupnotice'),
        PARAM_TEXT
    ));

    $ADMIN->add('localplugins', $settings);
}

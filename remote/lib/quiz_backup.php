<?php
// This file is part of Moo-backup. The Moo-backup project is MIT licensed;
// this file is an exception because it bootstraps the Moodle runtime.
//
// This file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this file. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrey "Telefaust" Bogachev
//
// Moodle quiz helpers for backup preparation.
// Run as the backup user after setup-moodledata-acl.sh (Moodle CLI bootstrap).
//
// Usage:
//   php quiz_backup.php list --moodle-root=/var/www/moodle
//   php quiz_backup.php env-check --moodle-root=/var/www/moodle
//   php quiz_backup.php contrib-list --moodle-root=/var/www/moodle

define('CLI_SCRIPT', true);

/**
 * @param array<int, string> $argv
 * @return array{command: string, moodleroot: string}
 */
function quiz_backup_parse_args(array $argv): array {
    $command = '';
    $moodleroot = '';

    for ($i = 1, $n = count($argv); $i < $n; $i++) {
        $arg = $argv[$i];
        if ($arg === '--moodle-root' && isset($argv[$i + 1])) {
            $moodleroot = $argv[++$i];
            continue;
        }
        if (strpos($arg, '--moodle-root=') === 0) {
            $moodleroot = substr($arg, strlen('--moodle-root='));
            continue;
        }
        if ($arg === '--help' || $arg === '-h') {
            $command = 'help';
            continue;
        }
        if ($command === '' && $arg[0] !== '-') {
            $command = $arg;
        }
    }

    return [
        'command' => $command,
        'moodleroot' => $moodleroot,
    ];
}

/**
 * @return never
 */
function quiz_backup_fail(string $message): void {
    fwrite(STDERR, $message . PHP_EOL);
    exit(1);
}

/**
 * @param mixed $data
 */
function quiz_backup_json($data, bool $pretty = false): void {
    while (ob_get_level() > 0) {
        ob_end_clean();
    }
    $flags = JSON_UNESCAPED_UNICODE;
    if ($pretty) {
        $flags |= JSON_PRETTY_PRINT;
    }
    echo json_encode($data, $flags) . PHP_EOL;
}

function quiz_backup_require_moodle(string $moodleroot): void {
    global $CFG;

    if ($moodleroot === '' || !is_dir($moodleroot)) {
        quiz_backup_fail('ERROR: --moodle-root is required and must exist');
    }

    $configphp = rtrim($moodleroot, '/') . '/config.php';
    if (!is_readable($configphp)) {
        quiz_backup_fail('ERROR: config.php not readable in moodle root');
    }

    ob_start();
    require_once($configphp);
    require_once($CFG->dirroot . '/mod/quiz/locallib.php');
    ob_end_clean();

    $CFG->debug = 0;
    $CFG->debugdisplay = 0;
}

function quiz_backup_collect_open_attempts(): array {
    global $DB;

    $now = time();
    $records = $DB->get_records_select(
        'quiz_attempts',
        "state IN ('inprogress', 'overdue')",
        null,
        'timestart ASC'
    );

    $rows = [];
    foreach ($records as $att) {
        $quiz = $DB->get_record('quiz', ['id' => $att->quiz], 'id,name,course', MUST_EXIST);
        $course = $DB->get_record('course', ['id' => $quiz->course], 'id,shortname,fullname', MUST_EXIST);
        $user = $DB->get_record('user', ['id' => $att->userid], 'id,firstname,lastname,email', MUST_EXIST);

        $endtime = null;
        $secondsleft = null;
        $deadlineknown = false;

        try {
            $quizobj = mod_quiz\quiz_settings::create((int) $att->quiz, (int) $att->userid);
            $accessmanager = $quizobj->get_access_manager($now);
            $endtime = $accessmanager->get_end_time($att);
            if ($endtime !== false) {
                $deadlineknown = true;
                $secondsleft = max(0, (int) $endtime - $now);
            }
        } catch (Throwable $e) {
            // Unknown deadline for this attempt.
        }

        $rows[] = [
            'attempt_id' => (int) $att->id,
            'quiz_id' => (int) $quiz->id,
            'quiz_name' => format_string($quiz->name, true),
            'course_shortname' => $course->shortname,
            'user_id' => (int) $user->id,
            'user_name' => fullname($user),
            'user_email' => $user->email,
            'state' => $att->state,
            'timestart' => (int) $att->timestart,
            'deadline_epoch' => ($endtime === false || $endtime === null) ? null : (int) $endtime,
            'seconds_left' => $secondsleft,
            'deadline_known' => $deadlineknown,
        ];
    }

    return $rows;
}

function quiz_backup_summarize_attempts(array $attempts): array {
    $maxleft = null;
    $unknown = false;

    foreach ($attempts as $row) {
        if (empty($row['deadline_known'])) {
            $unknown = true;
            continue;
        }
        if ($row['seconds_left'] === null) {
            continue;
        }
        $maxleft = ($maxleft === null)
            ? (int) $row['seconds_left']
            : max($maxleft, (int) $row['seconds_left']);
    }

    return [
        'count' => count($attempts),
        'max_seconds_left' => $maxleft,
        'has_unknown_deadline' => $unknown,
        'attempts' => $attempts,
    ];
}

function quiz_backup_cmd_list(): void {
    quiz_backup_json(quiz_backup_summarize_attempts(quiz_backup_collect_open_attempts()));
}

function quiz_backup_plugin_display_name(string $plugintype, string $pluginname, string $plugindir): string {
    $versionphp = rtrim($plugindir, '/') . '/version.php';
    if (!is_readable($versionphp)) {
        return $pluginname;
    }

    $plugin = new stdClass();
    $plugin->component = $plugintype . '_' . $pluginname;
    $module = $plugin;

    try {
        include($versionphp);
    } catch (Throwable $e) {
        return $pluginname;
    }

    if (!empty($plugin->displayname) && is_string($plugin->displayname)) {
        return $plugin->displayname;
    }
    if (!empty($module->displayname) && is_string($module->displayname)) {
        return $module->displayname;
    }

    return $pluginname;
}

function quiz_backup_plugin_is_standard(string $plugintype, string $pluginname): bool {
    static $standardcache = [];

    if (!array_key_exists($plugintype, $standardcache)) {
        $standard = core\plugin_manager::standard_plugins_list($plugintype);
        $standardcache[$plugintype] = is_array($standard) ? array_flip($standard) : [];
    }

    return isset($standardcache[$plugintype][$pluginname]);
}

function quiz_backup_quizaccess_installed(): bool {
    $manager = core\plugin_manager::instance();
    $info = $manager->get_plugin_info('quizaccess_backupnotice');
    return $info !== null && $info->is_installed_and_upgraded();
}

function quiz_backup_cmd_env_check(): void {
    quiz_backup_json([
        'ok' => true,
        'quizaccess_backupnotice_installed' => quiz_backup_quizaccess_installed(),
    ]);
}

function quiz_backup_cmd_contrib_list(): void {
    $types = core_component::get_plugin_types();
    ksort($types);

    foreach ($types as $plugintype => $unused) {
        $plugins = core_component::get_plugin_list($plugintype);
        ksort($plugins);

        foreach ($plugins as $pluginname => $plugindir) {
            if (quiz_backup_plugin_is_standard($plugintype, $pluginname)) {
                continue;
            }

            $component = $plugintype . '_' . $pluginname;
            $display = quiz_backup_plugin_display_name($plugintype, $pluginname, $plugindir);
            echo $component . "\t" . $display . "\n";
        }
    }
}

function quiz_backup_cmd_help(): void {
    echo <<<TXT
Moo-backup Moodle CLI helper (Moodle API — run as backup user after setup-moodledata-acl.sh).

Commands:
  list                 JSON list of in-progress/overdue quiz attempts
  contrib-list         Tab-separated list of non-standard (contrib) plugins
  env-check            JSON: quizaccess_backupnotice installed (blocks new attempts during wait)

Options:
  --moodle-root=PATH   Moodle installation directory (required)

TXT;
}

register_shutdown_function(static function (): void {
    $err = error_get_last();
    if ($err === null) {
        return;
    }
    if (!in_array($err['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) {
        return;
    }
    fwrite(
        STDERR,
        'ERROR: PHP fatal: ' . $err['message'] . ' in ' . $err['file'] . ':' . $err['line'] . PHP_EOL
    );
});

$args = quiz_backup_parse_args($argv);

if ($args['command'] === '' || $args['command'] === 'help') {
    quiz_backup_cmd_help();
    exit(0);
}

quiz_backup_require_moodle($args['moodleroot']);

switch ($args['command']) {
    case 'list':
        quiz_backup_cmd_list();
        break;
    case 'contrib-list':
        quiz_backup_cmd_contrib_list();
        break;
    case 'env-check':
        quiz_backup_cmd_env_check();
        break;
    default:
        quiz_backup_fail('ERROR: unknown command: ' . $args['command']);
}

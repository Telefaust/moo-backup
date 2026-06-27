<?php
// This file is part of Moodle - http://moodle.org/

defined('MOODLE_INTERNAL') || die();

use mod_quiz\local\access_rule_base;
use mod_quiz\quiz_settings;

/**
 * Blocks new quiz attempts while Moo-backup writes backup-notice.json to dataroot.
 *
 * Does not override prevent_access() — students with in-progress attempts can continue.
 *
 * @package    quizaccess_backupnotice
 * @copyright  2026 Andrey "Telefaust" Bogachev
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */
class quizaccess_backupnotice extends access_rule_base {

    /** @var string Same file as local_backupnotice / Moo-backup scripts. */
    public const NOTICE_FILENAME = 'backup-notice.json';

    public static function make(quiz_settings $quizobj, $timenow, $canignoretimelimits) {
        if (!self::should_block_new_attempts()) {
            return null;
        }

        return new self($quizobj, $timenow);
    }

    /**
     * Whether backup prep is active and new attempts should be blocked.
     */
    public static function should_block_new_attempts(): bool {
        global $CFG;

        $path = $CFG->dataroot . '/' . self::NOTICE_FILENAME;
        if (!is_readable($path)) {
            return false;
        }

        $raw = @file_get_contents($path);
        if ($raw === false || trim($raw) === '') {
            return false;
        }

        $data = json_decode($raw, false);
        if (!is_object($data)) {
            return false;
        }

        if (property_exists($data, 'block_new_quiz_attempts') && empty($data->block_new_quiz_attempts)) {
            return false;
        }

        return true;
    }

    public function prevent_new_attempt($numprevattempts, $lastattempt) {
        if (has_capability('mod/quiz:preview', $this->quizobj->get_context())) {
            return false;
        }

        return get_string('preventnew', 'quizaccess_backupnotice');
    }

    public function description() {
        if (!self::should_block_new_attempts()) {
            return '';
        }

        return get_string('ruledescription', 'quizaccess_backupnotice');
    }
}

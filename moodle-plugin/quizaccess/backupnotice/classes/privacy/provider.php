<?php
// This file is part of Moodle - http://moodle.org/

namespace quizaccess_backupnotice\privacy;

defined('MOODLE_INTERNAL') || die();

use core_privacy\local\metadata\null_provider;

/**
 * Privacy provider — this plugin stores no personal data.
 *
 * @package    quizaccess_backupnotice
 * @copyright  2026 Andrey "Telefaust" Bogachev
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */
class provider implements null_provider {

    public static function get_reason(): string {
        return 'privacy:metadata';
    }
}

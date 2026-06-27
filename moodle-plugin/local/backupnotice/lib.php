<?php
// This file is part of Moodle - http://moodle.org/

defined('MOODLE_INTERNAL') || die();

/**
 * Plugin callbacks.
 *
 * @package    local_backupnotice
 * @copyright  2026 Andrey "Telefaust" Bogachev
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

/**
 * Site-wide banner while backup-notice.json exists in dataroot.
 *
 * @return string HTML
 */
function local_backupnotice_before_standard_top_of_body_html(): string {
    if (defined('CLI_SCRIPT') && CLI_SCRIPT) {
        return '';
    }

    return \local_backupnotice\notice::render_html();
}

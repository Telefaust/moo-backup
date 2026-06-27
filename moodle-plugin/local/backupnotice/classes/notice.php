<?php
// This file is part of Moodle - http://moodle.org/

namespace local_backupnotice;

defined('MOODLE_INTERNAL') || die();

/**
 * Reads backup-notice.json from dataroot and renders the banner.
 */
class notice {
    /** @var string Filename in dataroot, written by Moo-backup scripts. */
    public const NOTICE_FILENAME = 'backup-notice.json';

    /** @var object|null Cached notice for the current request. */
    private static ?object $cached = null;

    /** @var bool Whether cache was populated. */
    private static bool $cacheloaded = false;

    /**
     * Absolute path to the notice file.
     */
    public static function notice_path(): string {
        global $CFG;
        return $CFG->dataroot . '/' . self::NOTICE_FILENAME;
    }

    /**
     * Load and validate notice data from dataroot.
     *
     * @return object|null Decoded notice or null if absent/invalid.
     */
    public static function read(): ?object {
        if (self::$cacheloaded) {
            return self::$cached;
        }

        self::$cacheloaded = true;
        self::$cached = null;

        $path = self::notice_path();
        if (!is_readable($path)) {
            return null;
        }

        $raw = @file_get_contents($path);
        if ($raw === false || trim($raw) === '') {
            return null;
        }

        $data = json_decode($raw, false);
        if (!is_object($data)) {
            return null;
        }

        self::$cached = $data;
        return self::$cached;
    }

    /**
     * Whether the banner should be shown to the current user.
     */
    public static function should_show(): bool {
        global $CFG;

        if (during_initial_install()) {
            return false;
        }

        $enabled = get_config('local_backupnotice', 'enabled');
        if ($enabled === '0' || $enabled === 0) {
            return false;
        }

        if (!self::read()) {
            return false;
        }

        if (!isloggedin() || isguestuser()) {
            return !empty(get_config('local_backupnotice', 'showguests'));
        }

        return true;
    }

    /**
     * Resolve banner text.
     */
    public static function message_text(): string {
        $notice = self::read();
        if ($notice && !empty($notice->message) && is_string($notice->message)) {
            return trim($notice->message);
        }

        $configured = get_config('local_backupnotice', 'defaultmessage');
        if (is_string($configured) && trim($configured) !== '') {
            return trim($configured);
        }

        return get_string('default_notice', 'local_backupnotice');
    }

    /**
     * Parse maintenance_at to Unix timestamp, or null.
     */
    public static function maintenance_timestamp(): ?int {
        $notice = self::read();
        if (!$notice || empty($notice->maintenance_at)) {
            return null;
        }

        $value = $notice->maintenance_at;
        if (is_int($value)) {
            return $value > 0 ? $value : null;
        }

        if (!is_string($value)) {
            return null;
        }

        $ts = strtotime($value);
        return ($ts !== false && $ts > 0) ? $ts : null;
    }

    /**
     * Poll interval in seconds (0 = disabled).
     */
    public static function poll_interval(): int {
        $notice = self::read();
        if ($notice && isset($notice->poll_seconds)) {
            $poll = (int) $notice->poll_seconds;
            if ($poll >= 15 && $poll <= 300) {
                return $poll;
            }
        }
        return 60;
    }

    /**
     * Render banner HTML for page hooks.
     */
    /**
     * Inline CSS for the body hook (head is already printed; no $PAGE->requires->css()).
     */
    public static function inline_styles_html(): string {
        static $cached = null;
        if ($cached !== null) {
            return $cached;
        }

        $path = __DIR__ . '/../styles.css';
        if (!is_readable($path)) {
            $cached = '';
            return $cached;
        }

        $css = file_get_contents($path);
        $cached = ($css !== false && $css !== '') ? '<style>' . $css . '</style>' : '';
        return $cached;
    }

    public static function render_html(): string {
        if (!self::should_show()) {
            return '';
        }

        $message = self::message_text();
        $maintenanceat = self::maintenance_timestamp();
        $poll = self::poll_interval();
        $statusurl = (new \moodle_url('/local/backupnotice/status.php'))->out(false);

        $data = [
            'message' => $message,
            'maintenanceat' => $maintenanceat ?? 0,
            'statusurl' => $statusurl,
            'poll' => $poll,
        ];

        return self::render_template($data);
    }

    /**
     * Build banner markup (no Mustache dependency for minimal install).
     *
     * @param array $data Template data.
     */
    private static function render_template(array $data): string {
        $message = s($data['message']);
        $statusurl = s($data['statusurl']);
        $poll = (int) $data['poll'];
        $maintenanceat = (int) $data['maintenanceat'];

        $countdownhtml = '';
        $countdownjs = 'null';
        if ($maintenanceat > 0) {
            $countdownhtml = ' · <span class="local-backupnotice-countdown" data-maintenance-at="' . $maintenanceat . '">'
                . '<strong class="local-backupnotice-countdown-value"></strong></span>';
            $countdownjs = (string) $maintenanceat;
        }

        $polljs = $poll > 0 ? (string) $poll : '0';

        $styles = self::inline_styles_html();

        return <<<HTML
{$styles}
<div id="local-backupnotice-banner" class="local-backupnotice-banner" role="status" aria-live="polite">
    <div class="local-backupnotice-inner">
        <span class="local-backupnotice-line">{$message}{$countdownhtml}</span>
    </div>
</div>
<script>
(function() {
    var banner = document.getElementById('local-backupnotice-banner');
    if (!banner) { return; }
    var maintenanceAt = {$countdownjs};
    var countdownEl = banner.querySelector('.local-backupnotice-countdown-value');
    function updateCountdown() {
        if (!maintenanceAt || !countdownEl) { return; }
        var left = maintenanceAt - Math.floor(Date.now() / 1000);
        if (left <= 0) {
            countdownEl.textContent = '0:00';
            return;
        }
        var m = Math.floor(left / 60);
        var s = left % 60;
        countdownEl.textContent = m + ':' + (s < 10 ? '0' : '') + s;
    }
    updateCountdown();
    if (maintenanceAt) {
        setInterval(updateCountdown, 1000);
    }
    var poll = {$polljs};
    var statusUrl = '{$statusurl}';
    if (poll > 0 && statusUrl) {
        setInterval(function() {
            fetch(statusUrl, { credentials: 'same-origin', cache: 'no-store' })
                .then(function(response) {
                    if (response.status === 204) {
                        banner.remove();
                    }
                })
                .catch(function() {});
        }, poll * 1000);
    }
})();
</script>
HTML;
    }
}

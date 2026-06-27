<?php
// This file is part of Moodle - http://moodle.org/
//
// Lightweight JSON endpoint: 200 + notice fields, or 204 if absent.
// Used by banner polling to hide when the backup script removes the file.

require(__DIR__ . '/../../config.php');

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

if (!get_config('local_backupnotice', 'enabled')) {
    http_response_code(204);
    exit;
}

$notice = \local_backupnotice\notice::read();
if (!$notice) {
    http_response_code(204);
    exit;
}

echo json_encode([
    'message' => \local_backupnotice\notice::message_text(),
    'maintenance_at' => \local_backupnotice\notice::maintenance_timestamp(),
], JSON_UNESCAPED_UNICODE);

<?php
// Truncate the configured log file. POST only.
header('Content-Type: text/plain; charset=utf-8');

$plugin  = 'wg-watchdog';
$logFile = '/var/log/wg-watchdog.log';
if (function_exists('parse_plugin_cfg')) {
    $cfg = parse_plugin_cfg($plugin);
    if (!empty($cfg['LOG_FILE']) && preg_match('!^/[A-Za-z0-9_./-]+$!', $cfg['LOG_FILE'])) {
        $logFile = $cfg['LOG_FILE'];
    }
}

$ok = @file_put_contents($logFile, '') !== false;
@chmod($logFile, 0644);
$ts = date('Y-m-d H:i:s');
@file_put_contents($logFile, "[$ts] log cleared via web UI\n", FILE_APPEND);

echo $ok ? "Log cleared: $logFile" : "Failed to clear: $logFile";

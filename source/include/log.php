<?php
// Tail the last 200 lines of the configured log file.
header('Content-Type: text/plain; charset=utf-8');

$plugin  = 'wg-watchdog';
$logFile = '/var/log/wg-watchdog.log';
if (function_exists('parse_plugin_cfg')) {
    $cfg = parse_plugin_cfg($plugin);
    if (!empty($cfg['LOG_FILE']) && preg_match('!^/[A-Za-z0-9_./-]+$!', $cfg['LOG_FILE'])) {
        $logFile = $cfg['LOG_FILE'];
    }
}

if (!file_exists($logFile)) {
    echo "(log file not yet created: $logFile)";
    exit;
}

$out = shell_exec(sprintf('tail -n 200 %s 2>&1', escapeshellarg($logFile)));
echo ($out !== null && $out !== '') ? $out : '(empty)';

<?php
// Run a one-shot ping check and stream the result back to the page.
header('Content-Type: text/plain; charset=utf-8');

$cmd = '/usr/local/emhttp/plugins/wg-watchdog/scripts/watchdog.sh --test 2>&1';
$out = shell_exec($cmd);
echo ($out !== null && $out !== '') ? $out : "(no output)\n";

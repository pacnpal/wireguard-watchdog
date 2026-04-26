<?php
// Apply handler: validate POSTed settings, write cfg, reinstall cron.
// Output is rendered into the Dynamix progress iframe.

header('Content-Type: text/plain; charset=utf-8');

$cfgDir  = '/boot/config/plugins/wg-watchdog';
$cfgFile = "$cfgDir/wg-watchdog.cfg";

if (!is_dir($cfgDir)) {
    @mkdir($cfgDir, 0755, true);
}

$defaults = [
    'SERVICE_ENABLED' => 'no',
    'INTERFACE'       => 'wg0',
    'PEER_IP'         => '10.99.0.1',
    'INTERVAL'        => '60',
    'VERBOSE'         => 'no',
    'LOG_FILE'        => '/var/log/wg-watchdog.log',
];

$out = [];
foreach ($defaults as $k => $dv) {
    $v = isset($_POST[$k]) ? trim((string)$_POST[$k]) : $dv;

    // Strip anything that could escape a bash double-quoted string.
    $v = preg_replace('/["\r\n\\\\$`]/', '', $v);

    switch ($k) {
        case 'SERVICE_ENABLED':
        case 'VERBOSE':
            $v = ($v === 'yes') ? 'yes' : 'no';
            break;

        case 'INTERVAL':
            $v = (int)$v;
            if ($v < 20) $v = 20;
            $v = (string)$v;
            break;

        case 'INTERFACE':
            if (!preg_match('/^[A-Za-z0-9_.-]{1,15}$/', $v)) $v = $dv;
            break;

        case 'PEER_IP':
            if (!filter_var($v, FILTER_VALIDATE_IP)) $v = $dv;
            break;

        case 'LOG_FILE':
            if (!preg_match('!^/[A-Za-z0-9_./-]+$!', $v)) $v = $dv;
            break;
    }
    $out[$k] = $v;
}

$body = '';
foreach ($out as $k => $v) {
    $body .= sprintf("%s=\"%s\"\n", $k, $v);
}
file_put_contents($cfgFile, $body);
@chmod($cfgFile, 0644);

echo "Saved $cfgFile\n";
echo "----\n";
echo $body;
echo "----\n";

$cmd = '/usr/local/emhttp/plugins/wg-watchdog/scripts/install_cron.sh 2>&1';
$lines = [];
$rc    = 0;
exec($cmd, $lines, $rc);
echo implode("\n", $lines) . "\n";
echo "install_cron exit=$rc\n";

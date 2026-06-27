#!/usr/bin/env php
<?php
/**
 * Parse Moodle config.php without bootstrapping the application.
 *
 * Usage:
 *   parse_config.php /path/to/moodle              # JSON to stdout
 *   parse_config.php /path/to/moodle --shell      # shell-safe VAR=value lines
 *   parse_config.php /path/to/moodle --get dataroot
 */

declare(strict_types=1);

function usage(): void
{
    fwrite(STDERR, "Usage: parse_config.php /path/to/moodle [--json|--shell|--get FIELD|--bootstrap-dirs]\n");
    fwrite(STDERR, "       parse_config.php --bootstrap-dirs-dataroot /path/to/moodledata\n");
}

function extract_cfg_value(string $content, string $key): string
{
    $quotedKey = preg_quote($key, '/');

    if (preg_match('/\$CFG->' . $quotedKey . '\s*=\s*\'((?:\\\\\'|[^\'])*)\'\s*;/s', $content, $matches)) {
        return stripcslashes(str_replace("\\'", "'", $matches[1]));
    }

    if (preg_match('/\$CFG->' . $quotedKey . '\s*=\s*"((?:\\\\"|[^"])*")\s*;/s', $content, $matches)) {
        return stripcslashes(str_replace('\\"', '"', $matches[1]));
    }

    return '';
}

function extract_version_field(string $path, string $field): string
{
    if (!is_file($path)) {
        return '';
    }

    $content = file_get_contents($path);
    if ($content === false) {
        return '';
    }

    if (preg_match('/\$' . preg_quote($field, '/') . '\s*=\s*([^;]+);/s', $content, $matches)) {
        return trim($matches[1], " \t\n\r\"'");
    }

    return '';
}

/**
 * Moodle CLI bootstrap writable paths (defaults relative to dataroot).
 *
 * @return list<string>
 */
function resolve_bootstrap_dirs(string $dataroot, string $configContent): array
{
    $root = rtrim(str_replace('\\', '/', $dataroot), '/');
    if ($root === '') {
        return [];
    }

    $dirs = [$root];
    $defaults = [
        'tempdir' => '/temp',
        'cachedir' => '/cache',
        'localcachedir' => '/localcache',
    ];

    foreach ($defaults as $key => $suffix) {
        $value = $configContent !== '' ? extract_cfg_value($configContent, $key) : '';
        if ($value !== '') {
            $dirs[] = rtrim(str_replace('\\', '/', $value), '/');
        } else {
            $dirs[] = $root . $suffix;
        }
    }

    $dirs[] = $root . '/muc';

    $dirs = array_values(array_unique($dirs));
    sort($dirs);

    return $dirs;
}

function read_config_content(string $moodleroot): string
{
    $configFile = rtrim($moodleroot, "/\\") . '/config.php';
    if (!is_file($configFile)) {
        fwrite(STDERR, "config.php not found: {$configFile}\n");
        exit(1);
    }

    $content = file_get_contents($configFile);
    if ($content === false || $content === '') {
        fwrite(STDERR, "Cannot read config.php: {$configFile}\n");
        exit(1);
    }

    return $content;
}

function parse_moodle_config(string $moodleroot): array
{
    $content = read_config_content($moodleroot);

    $keys = ['dbtype', 'dbhost', 'dbname', 'dbuser', 'dbpass', 'prefix', 'wwwroot', 'dataroot'];
    $result = [];

    foreach ($keys as $key) {
        $result[$key] = extract_cfg_value($content, $key);
    }

    $result['moodle_version'] = '';
    $result['moodle_release'] = '';
    foreach ([$moodleroot . '/public/version.php', $moodleroot . '/version.php'] as $versionFile) {
        if (!is_file($versionFile)) {
            continue;
        }
        $result['moodle_version'] = extract_version_field($versionFile, 'version');
        $result['moodle_release'] = extract_version_field($versionFile, 'release');
        break;
    }

    return $result;
}

$arg1 = isset($argv[1]) ? trim(str_replace("\r", '', $argv[1])) : '';
$mode = $argv[2] ?? '--json';

if ($arg1 === '-h' || $arg1 === '--help') {
    usage();
    exit(1);
}

if ($arg1 === '--bootstrap-dirs-dataroot') {
    $dataroot = isset($argv[2]) ? trim(str_replace("\r", '', $argv[2])) : '';
    if ($dataroot === '') {
        fwrite(STDERR, "Missing dataroot path\n");
        usage();
        exit(1);
    }
    foreach (resolve_bootstrap_dirs($dataroot, '') as $dir) {
        echo $dir . "\n";
    }
    exit(0);
}

$moodleroot = $arg1;
if ($moodleroot === '') {
    usage();
    exit(1);
}

if ($mode === '--bootstrap-dirs') {
    $content = read_config_content($moodleroot);
    $dataroot = extract_cfg_value($content, 'dataroot');
    if ($dataroot === '') {
        fwrite(STDERR, "dataroot not found in config.php\n");
        exit(1);
    }
    foreach (resolve_bootstrap_dirs($dataroot, $content) as $dir) {
        echo $dir . "\n";
    }
    exit(0);
}

$config = parse_moodle_config($moodleroot);

if ($mode === '--get') {
    $field = $argv[3] ?? '';
    if ($field === '' || !array_key_exists($field, $config)) {
        fwrite(STDERR, "Unknown or missing field for --get\n");
        exit(1);
    }
    $value = $config[$field];
    if ($value === '') {
        fwrite(STDERR, "Empty value for field: {$field}\n");
        exit(1);
    }
    echo $value;
    exit(0);
}

if ($mode === '--shell') {
    $map = [
        'dbhost' => 'MOODLE_CFG_dbhost',
        'dbname' => 'MOODLE_CFG_dbname',
        'dbuser' => 'MOODLE_CFG_dbuser',
        'dbpass' => 'MOODLE_CFG_dbpass',
        'dbtype' => 'MOODLE_CFG_dbtype',
        'wwwroot' => 'MOODLE_CFG_wwwroot',
        'dataroot' => 'MOODLE_CFG_dataroot',
        'prefix' => 'MOODLE_CFG_dbprefix',
        'moodle_version' => 'MOODLE_VERSION',
        'moodle_release' => 'MOODLE_RELEASE',
    ];

    foreach ($map as $src => $var) {
        echo $var . '=' . escapeshellarg($config[$src] ?? '') . "\n";
    }
    exit(0);
}

if ($mode !== '--json' && $mode !== '') {
    fwrite(STDERR, "Unknown mode: {$mode}\n");
    usage();
    exit(1);
}

echo json_encode($config, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);

# Build local_backupnotice install zip (Moodle-compatible, POSIX paths).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
python (Join-Path $root 'build-zip.py')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

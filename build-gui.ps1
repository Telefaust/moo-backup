# Build portable Windows GUI: PyInstaller onedir + remote/restore/moodle-plugin.
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
Set-Location $Root

function Find-Python {
    $venvPy = Join-Path $Root '.venv\Scripts\python.exe'
    if (Test-Path -LiteralPath $venvPy) {
        return $venvPy
    }
    foreach ($cmd in @('py -3', 'python', 'python3')) {
        $name, $arg = $cmd -split ' ', 2
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { continue }
        if ($arg) {
            & $name $arg -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" 2>$null
        } else {
            & $name -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" 2>$null
        }
        if ($LASTEXITCODE -eq 0) {
            if ($arg) { return @($name, $arg) }
            return @($name)
        }
    }
    throw 'Python 3.10+ not found. Run run-gui.bat once to create .venv, or install Python.'
}

function Invoke-Python {
    param([string[]]$Python, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    if ($Python.Count -eq 1) {
        & $Python[0] @Args
    } else {
        & $Python[0] $Python[1] @Args
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $($Args -join ' ')"
    }
}

function Copy-Tree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Missing source directory: $Source"
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
}

function Copy-PluginPackage {
    param(
        [Parameter(Mandatory)][string]$DestinationRoot
    )
    $pluginDest = Join-Path $DestinationRoot 'moodle-plugin'
    $pluginDistDest = Join-Path $pluginDest 'dist'
    $readmeSrc = Join-Path $Root 'moodle-plugin\README.md'
    $distSrc = Join-Path $Root 'moodle-plugin\dist'

    if (-not (Test-Path -LiteralPath $readmeSrc)) {
        throw "Missing file: $readmeSrc"
    }
    if (-not (Test-Path -LiteralPath $distSrc)) {
        throw "Missing plugin dist directory: $distSrc (build-zip.py should create it)"
    }

    $licenseSrc = Join-Path $Root 'moodle-plugin\LICENSE'
    if (-not (Test-Path -LiteralPath $licenseSrc)) {
        throw "Missing file: $licenseSrc"
    }

    New-Item -ItemType Directory -Force -Path $pluginDistDest | Out-Null
    Copy-Item -LiteralPath $readmeSrc -Destination (Join-Path $pluginDest 'README.md') -Force
    Copy-Item -LiteralPath $licenseSrc -Destination (Join-Path $pluginDest 'LICENSE') -Force

    $patterns = @(
        'local_backupnotice_moodle40-*.zip',
        'quizaccess_backupnotice_moodle40-*.zip'
    )
    $copied = 0
    foreach ($pattern in $patterns) {
        $files = Get-ChildItem -Path $distSrc -Filter $pattern -File -ErrorAction SilentlyContinue
        if (-not $files) {
            throw "Plugin ZIP not found: $distSrc\$pattern"
        }
        foreach ($file in $files) {
            Copy-Item -LiteralPath $file.FullName -Destination $pluginDistDest -Force
            $copied++
        }
    }
    if ($copied -lt 2) {
        throw "Expected 2 plugin ZIP files in $pluginDistDest, got $copied"
    }
}

$python = Find-Python
Write-Host "Using Python: $($python -join ' ')"

Write-Host ''
Write-Host 'Installing build dependencies...'
Invoke-Python $python -m pip install --upgrade pip
Invoke-Python $python -m pip install -r (Join-Path $Root 'requirements.txt')
Invoke-Python $python -m pip install -r (Join-Path $Root 'requirements-dev.txt')

Write-Host ''
Write-Host 'Building Moodle plugin ZIPs...'
Invoke-Python $python (Join-Path $Root 'moodle-plugin\build-zip.py')

Write-Host ''
Write-Host 'Running PyInstaller...'
Invoke-Python $python -m PyInstaller --noconfirm --clean (Join-Path $Root 'moo-backup.spec')

$distDir = Join-Path $Root 'dist\Moo-backup'
if (-not (Test-Path -LiteralPath (Join-Path $distDir 'Moo-backup.exe'))) {
    throw "Expected exe not found: $distDir\Moo-backup.exe"
}

Write-Host ''
Write-Host 'Copying package data...'

Copy-Tree (Join-Path $Root 'remote') (Join-Path $distDir 'remote')
Copy-Tree (Join-Path $Root 'restore') (Join-Path $distDir 'restore')
Copy-PluginPackage -DestinationRoot $distDir
Copy-Item -LiteralPath (Join-Path $Root 'README.md') -Destination (Join-Path $distDir 'README.md') -Force
Copy-Item -LiteralPath (Join-Path $Root 'LICENSE') -Destination (Join-Path $distDir 'LICENSE') -Force
Copy-Item -LiteralPath (Join-Path $Root 'THIRD_PARTY_LICENSES.txt') -Destination (Join-Path $distDir 'THIRD_PARTY_LICENSES.txt') -Force

$guiDest = Join-Path $distDir 'gui'
New-Item -ItemType Directory -Force -Path $guiDest | Out-Null
Copy-Item -LiteralPath (Join-Path $Root 'gui\profiles.json.example') -Destination (Join-Path $guiDest 'profiles.json.example') -Force
New-Item -ItemType Directory -Force -Path (Join-Path $guiDest 'keys') | Out-Null

$portableReadme = Join-Path $distDir 'PORTABLE.txt'
@'
Moo-backup — portable Windows package

Documentation: README.md (project overview and usage).
Plugin install ZIPs: moodle-plugin\dist\*.zip (see moodle-plugin\README.md).

Run Moo-backup.exe from this folder (keep _internal\ and sibling folders intact).

First run:
  1. Copy gui\profiles.json.example to gui\profiles.json and edit, or use Connections in the GUI.
  2. Connect and Deploy scripts to the Linux host.
  3. Install Moodle plugins from moodle-plugin\dist\*.zip.

Updating backup scripts without rebuilding the exe: replace the remote\ folder from a newer build, then Deploy scripts in the GUI.
'@ | Set-Content -LiteralPath $portableReadme -Encoding UTF8

$zipPath = Join-Path $Root 'dist\Moo-backup-portable.zip'
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

Write-Host ''
Write-Host "Creating $zipPath ..."
Compress-Archive -Path $distDir -DestinationPath $zipPath -CompressionLevel Optimal

Write-Host ''
Write-Host 'Done.'
Write-Host "  Folder: $distDir"
Write-Host "  ZIP:    $zipPath"

@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "ROOT=%CD%"
set "VENV=%ROOT%\.venv"
set "VPY=%VENV%\Scripts\python.exe"
set "REQ=%ROOT%\requirements.txt"

echo Moo-backup GUI launcher
echo.

REM --- find Python 3 ---
set "PY="
where py >nul 2>&1 && set "PY=py -3"
if not defined PY (
    where python >nul 2>&1 && set "PY=python"
)
if not defined PY (
    where python3 >nul 2>&1 && set "PY=python3"
)
if not defined PY (
    echo [ERROR] Python 3 not found.
    echo Install from https://www.python.org/ and enable "Add python.exe to PATH".
    goto :fail
)

%PY% -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Python 3.10+ required.
    %PY% --version
    goto :fail
)

echo Using: %PY%
%PY% --version

REM --- validate existing venv (catches copies from another machine) ---
if exist "%VPY%" (
    "%VPY%" -c "import sys" >nul 2>&1
    if errorlevel 1 (
        echo.
        echo [WARN] .venv is invalid or from another machine, rebuilding...
        rmdir /s /q "%VENV%"
    )
)

REM --- create venv if missing ---
if not exist "%VPY%" (
    echo.
    echo Creating virtual environment in .venv ...
    %PY% -m venv "%VENV%"
    if errorlevel 1 (
        echo [ERROR] Failed to create .venv
        goto :fail
    )
)

REM --- dependencies ---
"%VPY%" -c "import paramiko; import tkinter" >nul 2>&1
if errorlevel 1 (
    echo.
    echo Installing dependencies from requirements.txt ...
    "%VPY%" -m pip install --upgrade pip
    if errorlevel 1 goto :pip_fail
    "%VPY%" -m pip install -r "%REQ%"
    if errorlevel 1 goto :pip_fail
)

"%VPY%" -c "import tkinter" >nul 2>&1
if errorlevel 1 (
    echo.
    echo [ERROR] tkinter is not available in this Python installation.
    echo Reinstall Python and enable the "tcl/tk and IDLE" option.
    goto :fail
)

echo.
echo Starting GUI ...

set "VPYW=%VENV%\Scripts\pythonw.exe"
if exist "%VPYW%" (
    start "" "%VPYW%" "%ROOT%\gui\main.py"
) else (
    start "" "%VPY%" "%ROOT%\gui\main.py"
)
exit /b 0

:pip_fail
echo [ERROR] pip install failed. Check network access and try again.
goto :fail

:fail
echo.
pause
exit /b 1

@echo off
setlocal
title DolphinDB Path Migration and Launcher

rem Run migration and the existing launcher in one elevated process chain.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    set "DDB_MIGRATION_ENTRY=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/d','/c',('""' + $env:DDB_MIGRATION_ENTRY + '""') -Verb RunAs" >nul 2>&1
    exit /b
)

cd /d "%~dp0"

echo ============================================
echo   DolphinDB local8848 path migration
echo   Current directory: %cd%
echo ============================================
echo.

if not exist "%~dp0_repair_local8848_path.ps1" (
    echo [ERROR] Missing _repair_local8848_path.ps1
    echo         Keep the BAT and PowerShell script in the same root directory.
    pause
    exit /b 1
)

echo [1/2] Checking and refreshing stored local8848 paths...
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0_repair_local8848_path.ps1"
if errorlevel 1 goto repair_failed

echo.
echo [2/2] Path check passed. Locating the existing DolphinDB launcher...
set "DDB_MIGRATION_ROOT=%~dp0"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$root=$env:DDB_MIGRATION_ROOT; $self=[IO.Path]::GetFullPath('%~f0'); $launcher=Get-ChildItem -LiteralPath $root -Filter '*.bat' -File | Where-Object { $_.FullName -ne $self -and (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'DolphinDB V3\.00\.6 \+ Starfish Launcher' } | Select-Object -First 1; if(-not $launcher){Write-Host '[ERROR] Existing DolphinDB launcher was not found.'; exit 2}; Write-Host ('Starting: ' + $launcher.Name); Start-Process -FilePath $launcher.FullName -Wait"
if errorlevel 1 goto launcher_failed

echo Migration check completed. The existing launcher has been started.
exit /b 0

:repair_failed
echo.
echo [ERROR] Path migration did not complete. DolphinDB was not started.
echo         Read the message above. Failed writes are rolled back automatically.
pause
exit /b 1

:launcher_failed
echo.
echo [ERROR] Path migration passed, but the existing launcher could not be started.
pause
exit /b 1

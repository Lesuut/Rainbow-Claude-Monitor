@echo off
REM Starts the panel. The server reads config.json and opens the browser itself
REM (set "openBrowser": false there to stop it doing that).
REM Put a shortcut to this file in shell:startup to have it run at logon.
cd /d "%~dp0"
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"

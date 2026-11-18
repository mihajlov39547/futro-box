@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sync-PK2-ToFutro.ps1" -FutroHost 192.168.0.8 -Build
exit /b %errorlevel%
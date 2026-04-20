@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-dev-tools.ps1" %*
exit /b %errorlevel%

@echo off
REM Cihui one-click launcher. All logic lives in run-cihui.ps1.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-cihui.ps1"
if errorlevel 1 pause

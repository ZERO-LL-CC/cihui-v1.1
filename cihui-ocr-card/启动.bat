@echo off
chcp 65001 >nul
echo ============================================
echo   词慧 OCR 功能卡 - 启动中...
echo ============================================

cd /d "%~dp0backend"

set PYTHON=C:\Python312\python.exe

if not exist "%PYTHON%" (
    echo [错误] 未找到 Python 3.12: %PYTHON%
    pause
    exit /b 1
)

echo.
echo 服务启动后，浏览器访问: http://localhost:8000
echo 按 Ctrl+C 停止服务
echo.

"%PYTHON%" main.py
pause

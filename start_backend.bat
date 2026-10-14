@echo off
title Kyiv Alert Backend Server
cd /d "%~dp0"
echo ==========================================
echo Starting Kyiv Alert Backend Server...
echo ==========================================
echo.
echo Press CTRL+C to stop the server.
echo.

cd backend
python -m uvicorn main:app --host 0.0.0.0 --port 8000

if %errorlevel% neq 0 (
    echo.
    echo ------------------------------------------
    echo ERROR: Server failed to start!
    echo Please check the error messages above.
    echo ------------------------------------------
)
pause

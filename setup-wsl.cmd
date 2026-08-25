@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-wsl.ps1"
if errorlevel 1 (
  echo.
  echo Setup failed. Review the error above.
  pause
  exit /b 1
)
echo.
echo Setup completed successfully.
pause

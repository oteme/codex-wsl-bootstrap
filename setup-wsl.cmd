@echo off
setlocal
set "SETUP_PS1=%TEMP%\codex-wsl-bootstrap-setup-%RANDOM%-%RANDOM%.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/oteme/codex-wsl-bootstrap/main/setup-wsl.ps1' -OutFile '%SETUP_PS1%'"
if errorlevel 1 (
  echo.
  echo Failed to download the latest setup script.
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%"
set "SETUP_EXIT=%ERRORLEVEL%"
del /q "%SETUP_PS1%" >nul 2>&1

if not "%SETUP_EXIT%"=="0" (
  echo.
  echo Setup failed. Review the error above.
  pause
  exit /b %SETUP_EXIT%
)
echo.
echo Setup completed successfully.
pause

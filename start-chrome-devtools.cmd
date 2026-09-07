@echo off
setlocal
set "DEVTOOLS_PORT=%~1"
if "%DEVTOOLS_PORT%"=="" set "DEVTOOLS_PORT=9222"
if not "%DEVTOOLS_PORT%"=="9222" if not "%DEVTOOLS_PORT%"=="9223" (
  echo Usage: start-chrome-devtools.cmd [9222 or 9223]
  exit /b 2
)
if not "%~2"=="" exit /b 2
set "CHROME_EXE=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROME_EXE%" set "CHROME_EXE=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROME_EXE%" set "CHROME_EXE=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROME_EXE%" (
  echo Google Chrome was not found. Install Chrome, then run this launcher again.
  pause
  exit /b 1
)
start "" "%CHROME_EXE%" --remote-debugging-address=127.0.0.1 --remote-debugging-port=%DEVTOOLS_PORT% --user-data-dir="%LOCALAPPDATA%\CodexChromeDevTools-%DEVTOOLS_PORT%"
if errorlevel 1 exit /b 1
echo Chrome started with a dedicated profile. Check connectivity in WSL with doctor.sh --check-browser=%DEVTOOLS_PORT%.

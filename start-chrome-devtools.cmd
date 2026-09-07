@echo off
setlocal
set "CHROME_EXE=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROME_EXE%" set "CHROME_EXE=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROME_EXE%" set "CHROME_EXE=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROME_EXE%" (
  echo Google Chrome was not found. Install Chrome, then run this launcher again.
  pause
  exit /b 1
)
start "" "%CHROME_EXE%" --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --user-data-dir="%LOCALAPPDATA%\CodexChromeDevTools"
if errorlevel 1 exit /b 1
echo Chrome started with a dedicated profile. Check connectivity in WSL with doctor.sh --check-browser.

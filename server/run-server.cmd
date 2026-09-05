@echo off
rem Notables note server launcher. Started by start-hidden.vbs from the scheduled
rem task, or run directly from a console to watch it in the foreground.
setlocal
set "SERVER_DIR=%~dp0"
if not defined NOTABLES_VAULT set "NOTABLES_VAULT=%USERPROFILE%\Notables"
if not defined NOTABLES_PORT set "NOTABLES_PORT=8787"

rem Already listening? Nothing to do - this is the normal watchdog outcome.
netstat -ano -p tcp | findstr /r /c:":%NOTABLES_PORT% .*LISTENING" >nul 2>&1
if not errorlevel 1 exit /b 0

set "NODE=%ProgramFiles%\nodejs\node.exe"
if not exist "%NODE%" set "NODE=node"

if not exist "%NOTABLES_VAULT%\logs" mkdir "%NOTABLES_VAULT%\logs" >nul 2>&1
echo [%DATE% %TIME%] launching note-server >> "%NOTABLES_VAULT%\logs\stdout.log"
"%NODE%" "%SERVER_DIR%note-server.js" >> "%NOTABLES_VAULT%\logs\stdout.log" 2>&1
echo [%DATE% %TIME%] note-server exited with %ERRORLEVEL% >> "%NOTABLES_VAULT%\logs\stdout.log"
exit /b %ERRORLEVEL%

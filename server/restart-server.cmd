@echo off
call "%~dp0stop-server.cmd"
timeout /t 2 /nobreak >nul
wscript.exe //B //Nologo "%~dp0start-hidden.vbs"
echo restarted

@echo off
rem Stop every running note-server (does NOT disable the scheduled task, so the
rem watchdog will start it again within a couple of minutes - see README.md).
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "$p = Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | Where-Object { $_.CommandLine -like '*note-server.js*' }; if ($p) { $p | ForEach-Object { Write-Host ('stopping pid ' + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force } } else { Write-Host 'note-server is not running' }"

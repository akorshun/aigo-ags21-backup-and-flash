@echo off
rem Aigo AGS21: backup of the important stock partitions and OpenWrt install.
rem Arguments are passed through, e.g.:  ags21-flash.cmd -Mode Backup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ags21-flash.ps1" %*
pause

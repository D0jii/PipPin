@echo off
title PipPin (debug)
echo Starting PipPin with the console visible.
echo Errors will appear below. Close this window to quit PipPin.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PipPin.ps1"
echo.
echo PipPin exited.
pause

@echo off
rem Opens the fork manager menu. See README.md.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fork-manager.ps1" %*
if errorlevel 1 pause

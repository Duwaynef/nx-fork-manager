@echo off
rem Opens the fork manager window. The menu (ForkManager.cmd) and this window share the same settings and forks.
start "" powershell -NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0fork-manager-gui.ps1" %*

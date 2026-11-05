@echo off
rem andon: double-click this file to install andon. It runs install.ps1 in this folder
rem with Windows PowerShell 5.1. It needs no administrator rights and does not use the network.
setlocal EnableExtensions DisableDelayedExpansion
if not exist "%~dp0install.ps1" goto missing
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 goto failed
exit /b 0

:missing
echo install.ps1 was not found next to install.cmd.
echo Extract the zip first (right-click the zip and choose "Extract All"), then run install.cmd in the extracted folder.
pause
exit /b 1

:failed
pause
exit /b 1

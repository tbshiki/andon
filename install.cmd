@echo off
rem andon: double-click this file to install andon. It runs install.ps1 in this folder
rem with Windows PowerShell 5.1. It needs no administrator rights and does not use the network.
setlocal EnableExtensions DisableDelayedExpansion
if not exist "%~dp0install.ps1" goto missing
rem A 32-bit program that opens this file runs it in 32-bit cmd.exe, where System32 is redirected to SysWOW64
rem and the 32-bit PowerShell cannot see conhost.exe. Sysnative exists only there and leads to the 64-bit one.
set "ANDON_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "ANDON_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%ANDON_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
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

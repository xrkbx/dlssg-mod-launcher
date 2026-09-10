@echo off
REM Double-click launcher for the DLSSG SM86 mod tool.
REM Runs the PowerShell GUI with the local execution policy bypassed for this process only.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DLSSG-Launcher.ps1"
if errorlevel 1 (
  echo.
  echo The launcher exited with an error. Read the message above, then press a key.
  pause >nul
)

@echo off
rem Launches the onn Wall Display Deployer.
rem -ExecutionPolicy Bypass applies to this process only; nothing on the PC is changed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0OnnDeploy.ps1"

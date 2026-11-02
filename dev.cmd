@echo off
rem Double-click: opens a PowerShell session with the setup / build / rebuild / flash / clean commands.
title system_off sample
powershell.exe -NoLogo -NoExit -ExecutionPolicy Bypass -Command ". '%~dp0dev.ps1'"

@echo off
rem Avvia DLSS Updater (chiede i permessi di amministratore per scrivere nelle cartelle dei giochi).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0DLSSUpdater.ps1"

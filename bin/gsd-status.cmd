@echo off
powershell -ExecutionPolicy Bypass -NoProfile -Command "& { . '%USERPROFILE%\.gsd-global\scripts\gsd-profile-functions.ps1'; gsd-status }"

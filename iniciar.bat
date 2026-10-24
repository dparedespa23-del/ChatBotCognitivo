@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Chatbot Cognitivo - Inicio local
rem Evita heredar modulos incompatibles si se abre desde PowerShell 7 o un IDE.
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules;%ProgramFiles%\WindowsPowerShell\Modules"
echo La primera vez se descargaran las herramientas y el modelo que falten.
echo Necesitas Internet. Espera a que aparezca LISTO y deja esta ventana abierta.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0iniciar.ps1" %*
set "resultado=%ERRORLEVEL%"
if not "%resultado%"=="0" (
    echo.
    echo El inicio no termino correctamente. Lee el mensaje anterior.
    pause
)
exit /b %resultado%

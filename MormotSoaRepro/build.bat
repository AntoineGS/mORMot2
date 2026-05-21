@echo off
rem  Build the repro.  Usage:  build.bat Win64   |   build.bat Linux64
setlocal
if "%~1"=="" (echo Usage: build.bat ^<Win64^|Linux64^> & exit /b 1)
if exist "C:\Multidev\Tools\ensure-envoptions.cmd" call "C:\Multidev\Tools\ensure-envoptions.cmd" 37.0 --silent
call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
msbuild "%~dp0MormotSoaRepro.dproj" /t:build /p:config=Debug;Platform=%~1 /nologo /v:minimal
exit /b %ERRORLEVEL%

@echo off
rem Builds client\native\bin\belt_sim.windows.template_release.x86_64.dll with MSVC (docs/RUNNING.md).
setlocal
set VCVARS=
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath`) do set VCVARS=%%i\VC\Auxiliary\Build\vcvars64.bat
if not defined VCVARS (echo MSVC not found & exit /b 1)
call "%VCVARS%" >nul
cd /d "%~dp0"
python -m SCons target=template_release -j4 %*

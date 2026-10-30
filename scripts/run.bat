@echo off
rem Run the game on Windows (scripts\run.bat).
rem
rem Checks PATH for love, offers a one-time local install into
rem scripts\bin\ from the official LOVE release on approval, then boots
rem the game the way scripts/run.sh does (love app/ --dev). Dev-only
rem tooling (StyLua, LuaLS, hook setup) stays Unix-side.
setlocal

set "ROOT=%~dp0.."
set "BINDIR=%~dp0bin"
set "LOVE_VERSION=11.5"
set "LOVEDIR=%BINDIR%\love-%LOVE_VERSION%-win64"

if exist "%LOVEDIR%\love.exe" (
  set "LOVE=%LOVEDIR%\love.exe"
  goto :run
)

where love >nul 2>nul
if %ERRORLEVEL%==0 (
  for /F "delims=" %%L in ('where love 2^>nul') do (
    set "LOVE=%%L"
    goto :run
  )
)

echo love %LOVE_VERSION% was not found on PATH.
choice /C YN /N /M "Install it into scripts\bin from the official release download? [y/N]"
if %ERRORLEVEL%==1 goto :install
echo Install LOVE %LOVE_VERSION% from https://love2d.org/ , then re-run this script.
exit /b 1

:install
if /I not "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
  echo No official LOVE %LOVE_VERSION% download for %PROCESSOR_ARCHITECTURE%; install it from https://love2d.org/ , then re-run this script.
  exit /b 1
)
set "ASSET=love-%LOVE_VERSION%-win64.zip"
set "URL=https://github.com/love2d/love/releases/download/%LOVE_VERSION%/%ASSET%"
if not exist "%BINDIR%" mkdir "%BINDIR%"
echo Downloading %ASSET% ...
where curl >nul 2>nul
if %ERRORLEVEL%==0 (
  curl.exe --fail --location --retry 3 --show-error --output "%BINDIR%\%ASSET%" "%URL%"
) else (
  powershell -NoProfile -Command "Invoke-WebRequest -Uri '%URL%' -OutFile '%BINDIR%\%ASSET%'"
)
if %ERRORLEVEL% neq 0 exit /b 1
where tar >nul 2>nul
if %ERRORLEVEL%==0 (
  tar -xf "%BINDIR%\%ASSET%" -C "%BINDIR%"
) else (
  powershell -NoProfile -Command "Expand-Archive -Path '%BINDIR%\%ASSET%' -DestinationPath '%BINDIR%' -Force"
)
if %ERRORLEVEL% neq 0 exit /b 1
del "%BINDIR%\%ASSET%"
if not exist "%LOVEDIR%\love.exe" (
  echo The download did not contain %LOVEDIR%\love.exe.
  exit /b 1
)
set "LOVE=%LOVEDIR%\love.exe"

:run
set "PATH=%LOVEDIR%;%PATH%"
"%LOVE%" --version
pushd "%ROOT%"
"%LOVE%" app --dev %*
set "STATUS=%ERRORLEVEL%"
popd
exit /b %STATUS%

@echo off
setlocal EnableExtensions

rem Optional arg: "auto" to skip key prompt when a saved key exists
set "AUTO_MODE="
if /I "%~1"=="auto" set "AUTO_MODE=1"

rem Keep NuGet and Flutter on PATH for this run
set "PATH=C:\src\flutter\bin;C:\tools\nuget;%PATH%"

rem Try to load key from a local file first (not committed)
set "KEY_FILE=%~dp0openai_key.txt"
if exist "%KEY_FILE%" set /p OPENAI_API_KEY=<"%KEY_FILE%"

rem Try to load SMTP settings from a local file (smtp_env.txt)
set "SMTP_FILE=%~dp0smtp_env.txt"
if not exist "%SMTP_FILE%" goto :skip_smtp_load
for /f "usebackq tokens=1* delims==" %%A in ("%SMTP_FILE%") do (
  if /I "%%~A"=="SMTP_HOST" set "SMTP_HOST=%%~B"
  if /I "%%~A"=="SMTP_PORT" set "SMTP_PORT=%%~B"
  if /I "%%~A"=="SMTP_USER" set "SMTP_USER=%%~B"
  if /I "%%~A"=="SMTP_PASS" set "SMTP_PASS=%%~B"
  if /I "%%~A"=="SMTP_ENCRYPTION" set "SMTP_ENCRYPTION=%%~B"
)
:skip_smtp_load

rem Prompt for your OpenAI key (press Enter to keep detected value)
if not defined AUTO_MODE (
  echo.
  if "%OPENAI_API_KEY%"=="" (
    echo No key detected.
  ) else (
    echo Detected an existing OPENAI_API_KEY. Press Enter to keep it,
    echo or paste a new one now.
  )
  echo Paste your OpenAI API key ^(raw value, include sk-; no quotes^):
  set "TMP_INPUT="
  set /p TMP_INPUT=
  if not "%TMP_INPUT%"=="" set "OPENAI_API_KEY=%TMP_INPUT%"

  if "%OPENAI_API_KEY%"=="" (
    echo ERROR: No API key provided. Exiting.
    goto :end
  )
) else (
  if "%OPENAI_API_KEY%"=="" (
    echo No saved OPENAI_API_KEY found. Please run without "auto" to enter it.
    goto :end
  ) else (
    echo Using saved OPENAI_API_KEY.
  )
)

rem Optional: save for next time (only if a new key was entered this run)
if not "%TMP_INPUT%"=="" (
  echo.
  set "SAVE_ANS="
  set /p SAVE_ANS=Save key to openai_key.txt for next runs? [y/N]: 
  if /I "%SAVE_ANS%"=="Y" (
    >"%KEY_FILE%" echo %OPENAI_API_KEY%
    echo Saved to %KEY_FILE% ^(remember: this file is local and should not be shared^).
  )
)

rem Default model (you can change this)
if "%OPENAI_MODEL%"=="" (
  set "OPENAI_MODEL=gpt-4o-mini"
)

echo === Running Teddy on Windows ===
echo OPENAI_API_KEY: detected
echo OPENAI_MODEL: %OPENAI_MODEL%
rem Basic sanity check: warn if key doesn't look like sk-*
echo %OPENAI_API_KEY% | findstr /b /c:"sk-" >nul || echo WARNING: Key should start with sk- and be ~50+ characters.

rem Optional SMTP email settings (press Enter to skip)
echo.
echo Optional: configure SMTP email (recommended, uses your provider). Press Enter to keep current or skip.
set "USE_GMAIL="
set /p USE_GMAIL=Use Gmail preset for host/port/encryption? [y/N]: 
if /I "%USE_GMAIL%"=="Y" (
  set "SMTP_HOST=smtp.gmail.com"
  set "SMTP_PORT=587"
  set "SMTP_ENCRYPTION=starttls"
)
set /p SMTP_HOST=SMTP host (e.g., smtp.gmail.com) [%SMTP_HOST%]: 
set /p SMTP_PORT=SMTP port [587] (current %SMTP_PORT%): 
if "%SMTP_PORT%"=="" set SMTP_PORT=587
set /p SMTP_USER=SMTP username (email address) [%SMTP_USER%]: 
set /p SMTP_PASS=SMTP password or app password (input hidden not supported) [%SMTP_PASS%]: 
set /p SMTP_ENCRYPTION=Encryption [starttls^|ssl^|none] (default starttls) [%SMTP_ENCRYPTION%]: 
if "%SMTP_ENCRYPTION%"=="" set SMTP_ENCRYPTION=starttls

rem Optionally save SMTP settings
echo.
set "SAVE_SMTP="
set /p SAVE_SMTP=Save SMTP settings to smtp_env.txt for next runs? [y/N]: 
if /I "%SAVE_SMTP%"=="Y" (
  >"%SMTP_FILE%" echo SMTP_HOST=%SMTP_HOST%
  >>"%SMTP_FILE%" echo SMTP_PORT=%SMTP_PORT%
  >>"%SMTP_FILE%" echo SMTP_USER=%SMTP_USER%
  >>"%SMTP_FILE%" echo SMTP_PASS=%SMTP_PASS%
  >>"%SMTP_FILE%" echo SMTP_ENCRYPTION=%SMTP_ENCRYPTION%
  echo Saved SMTP settings to %SMTP_FILE% ^(local only; do not commit^).
)

flutter --version
flutter clean
flutter pub get
flutter run -d windows --dart-define=OPENAI_API_KEY="%OPENAI_API_KEY%" --dart-define=OPENAI_MODEL="%OPENAI_MODEL%" --dart-define=DEFAULT_EMAIL_TO="ai.projects.emails@gmail.com" --dart-define=SMTP_HOST="%SMTP_HOST%" --dart-define=SMTP_PORT="%SMTP_PORT%" --dart-define=SMTP_USER="%SMTP_USER%" --dart-define=SMTP_PASS="%SMTP_PASS%" --dart-define=SMTP_ENCRYPTION="%SMTP_ENCRYPTION%"

echo Exit code: %errorlevel%
pause

:end
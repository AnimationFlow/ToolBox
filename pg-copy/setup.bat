@echo off
where uv >nul 2>&1 || (
    echo uv not found - installing via winget...
    winget install astral-sh.uv
    echo.
    echo Restart this terminal after uv installs, then run setup.bat again.
    exit /b 1
)

uv venv
uv pip install -r requirements.txt

if exist .env (
    echo .env already exists - skipping credential setup.
    echo Delete .env and re-run setup.bat to reconfigure.
    goto done
)

echo.
echo --- Stage DB ---
set STAGE_HOST=
set /p STAGE_HOST=  Host:

set STAGE_PORT=5432
set /p STAGE_PORT=  Port [5432]:
if "%STAGE_PORT%"=="" set STAGE_PORT=5432

set STAGE_DBNAME=
set /p STAGE_DBNAME=  Database:

set STAGE_USER=
set /p STAGE_USER=  User:

set STAGE_PASSWORD=
set /p STAGE_PASSWORD=  Password:

echo.
echo --- Local DB ---
set LOCAL_HOST=localhost
set /p LOCAL_HOST=  Host [localhost]:
if "%LOCAL_HOST%"=="" set LOCAL_HOST=localhost

set LOCAL_PORT=5432
set /p LOCAL_PORT=  Port [5432]:
if "%LOCAL_PORT%"=="" set LOCAL_PORT=5432

set LOCAL_DBNAME=
set /p LOCAL_DBNAME=  Database:

set LOCAL_USER=postgres
set /p LOCAL_USER=  User [postgres]:
if "%LOCAL_USER%"=="" set LOCAL_USER=postgres

set LOCAL_PASSWORD=
set /p LOCAL_PASSWORD=  Password:

(
    echo STAGE_HOST=%STAGE_HOST%
    echo STAGE_PORT=%STAGE_PORT%
    echo STAGE_DBNAME=%STAGE_DBNAME%
    echo STAGE_USER=%STAGE_USER%
    echo STAGE_PASSWORD=%STAGE_PASSWORD%
    echo.
    echo LOCAL_HOST=%LOCAL_HOST%
    echo LOCAL_PORT=%LOCAL_PORT%
    echo LOCAL_DBNAME=%LOCAL_DBNAME%
    echo LOCAL_USER=%LOCAL_USER%
    echo LOCAL_PASSWORD=%LOCAL_PASSWORD%
) > .env

echo.
echo .env written.

:done
echo.
echo Setup complete. Run start.bat to launch.

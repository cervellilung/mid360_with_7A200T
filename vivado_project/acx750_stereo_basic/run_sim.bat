@echo off
setlocal
pushd "%~dp0..\.."
py tools\run_build.py --name stereo_basic_regression --kind simulation --cwd . --log vivado_project\logs\stereo_basic_regression.log --estimate 60 -- py "%~dp0scripts\simulate.py"
set "test_exit=%errorlevel%"
popd
exit /b %test_exit%

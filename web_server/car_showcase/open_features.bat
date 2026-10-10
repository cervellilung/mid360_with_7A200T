@echo off
cd /d "%~dp0..\.."
".venv_linux_host\Scripts\python.exe" -m web_server.car_showcase.serve --port 8870 --output sample\car_showcase\feature_corridor_20261009 --page angular_viewer.html
pause

@echo off
cd /d "%~dp0..\.."
".venv_linux_host\Scripts\python.exe" -m web_server.car_showcase.serve --port 8771 --output sample\car_showcase\fast_corridor_20261009 --page angular_viewer.html
pause

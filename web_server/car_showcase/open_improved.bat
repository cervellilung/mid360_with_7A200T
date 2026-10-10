@echo off
cd /d "%~dp0\..\.."
py -m web_server.car_showcase.serve --output sample/car_showcase/surface_improved_20261008 --port 8768
pause

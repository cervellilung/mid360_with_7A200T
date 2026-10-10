@echo off
setlocal
cd /d "%~dp0..\.."
set "PYTHONIOENCODING=utf-8"
set "OPENBLAS_NUM_THREADS=1"
set "OMP_NUM_THREADS=1"
if not exist "sample\car_showcase\planar_classroom_20261010_6m\manifest.json" (
  ".venv_linux_host\Scripts\python.exe" tools\run_build.py --name Python_classroom_6m --kind python --estimate 60 --log results\classroom_mesh_20261010\build.log -- ".venv_linux_host\Scripts\python.exe" -m web_server.car_showcase.build_planar_experiment --recording sample/radar/classroom_20261010_30s --out sample/car_showcase/planar_classroom_20261010_6m --times 3,7,11 --max-range 6 --support-angle 2.4
  if errorlevel 1 exit /b 1
)
".venv_linux_host\Scripts\python.exe" -m web_server.car_showcase.serve_planar --output sample/car_showcase/planar_classroom_20261010_6m
pause

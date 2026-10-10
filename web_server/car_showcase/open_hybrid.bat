@echo off
setlocal
cd /d "%~dp0..\.."
set "PYTHONIOENCODING=utf-8"
set "OPENBLAS_NUM_THREADS=1"
set "OMP_NUM_THREADS=1"
if not exist "sample\car_showcase\hybrid_corridor_6m\manifest.json" (
  ".venv_linux_host\Scripts\python.exe" tools\run_build.py --name Python_hybrid_6m --kind python --estimate 120 --log results\hybrid_mesh_6m\real.log -- ".venv_linux_host\Scripts\python.exe" -m web_server.car_showcase.build_planar_experiment --hybrid --max-range 6 --out sample\car_showcase\hybrid_corridor_6m
  if errorlevel 1 exit /b 1
)
".venv_linux_host\Scripts\python.exe" -m web_server.car_showcase.serve_planar --output sample\car_showcase\hybrid_corridor_6m
pause

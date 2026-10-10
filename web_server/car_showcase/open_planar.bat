@echo off
setlocal
cd /d "%~dp0..\.."
set "PYTHONIOENCODING=utf-8"
set "OPENBLAS_NUM_THREADS=1"
set "OMP_NUM_THREADS=1"
".venv_linux_host\Scripts\python.exe" -c "import json,pathlib,sys;p=pathlib.Path('sample/car_showcase/planar_corridor_6m/manifest.json');sys.exit(0 if p.exists() and json.loads(p.read_text(encoding='utf-8')).get('variants')==['angular','baseline','planar'] else 1)"
if errorlevel 1 (
  ".venv_linux_host\Scripts\python.exe" tools\run_build.py --name Python_planar_6m --kind python --estimate 160 --log results\planar_mesh_6m\real.log -- ".venv_linux_host\Scripts\python.exe" -m web_server.car_showcase.build_planar_experiment --max-range 6
  if errorlevel 1 exit /b 1
)
".venv_linux_host\Scripts\python.exe" -m web_server.car_showcase.serve_planar
pause

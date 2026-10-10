@echo off
setlocal
cd /d "%~dp0..\.."
set "PYTHONIOENCODING=utf-8"
set "OPENBLAS_NUM_THREADS=1"
set "OMP_NUM_THREADS=1"
".venv_linux_host\Scripts\python.exe" -c "import json,pathlib,sys;p=pathlib.Path('sample/car_showcase/planar_angular_support_6m/manifest.json');m=json.loads(p.read_text(encoding='utf-8')) if p.exists() else {};sys.exit(0 if m.get('variants')==['angular','baseline','planar'] and m.get('algorithm')=='planar_support_experiment_v2' and m.get('config',{}).get('angular_gap_support') else 1)"
if errorlevel 1 (
  ".venv_linux_host\Scripts\python.exe" tools\run_build.py --name Python_planar_6m --kind python --estimate 160 --log results\planar_angular_support\real.log -- ".venv_linux_host\Scripts\python.exe" -m web_server.car_showcase.build_planar_experiment --max-range 6 --out sample/car_showcase/planar_angular_support_6m
  if errorlevel 1 exit /b 1
)
".venv_linux_host\Scripts\python.exe" -m web_server.car_showcase.serve_planar --output sample/car_showcase/planar_angular_support_6m
pause

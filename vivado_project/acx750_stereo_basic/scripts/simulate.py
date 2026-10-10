"""Direct XSim entry, usable through tools/run_build.py without Vivado GUI Tcl."""
from pathlib import Path
import subprocess
import sys
import os

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[1]
LOGS = ROOT / 'vivado_project/logs/stereo_basic/direct_sim'
BIN = Path(os.environ.get('XILINX_VIVADO', 'C:/Xilinx/Vivado/2020.2')) / 'bin'

def run(tool, args):
    command = [str(BIN / (tool + '.bat')), *map(str, args)]
    if os.name == 'nt':
        command = ['cmd.exe', '/d', '/c', *command]
    proc = subprocess.run(command, cwd=LOGS, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, errors='replace')
    (LOGS / (tool + '_output.log')).write_text(proc.stdout, encoding='utf-8')
    print(f'{tool}: EXIT:{proc.returncode}', flush=True)
    if proc.returncode:
        print('\n'.join(proc.stdout.splitlines()[-25:]), flush=True)
        raise SystemExit(proc.returncode)
    return proc.stdout

def main():
    LOGS.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(HERE / 'scripts/reference.py'), str(LOGS)], check=True)
    (LOGS / 'run.tcl').write_text('run all\nquit\n', encoding='ascii')
    xpm = BIN.parent / 'data/ip/xpm'
    run('xvlog', ['--sv', '-work', 'xpm', xpm/'xpm_memory/hdl/xpm_memory.sv',
                 xpm/'xpm_cdc/hdl/xpm_cdc.sv', xpm/'xpm_fifo/hdl/xpm_fifo.sv'])
    vendor = HERE / 'acx750_stereo_basic.srcs/sources_1/imports/vendor_camera'
    run('xvlog', [vendor/name for name in ('camera_init.v','ov5640_init_table_rgb.v','i2c_control.v','i2c_bit_shift.v')])
    run('xvlog', ['--sv', *sorted((HERE / 'acx750_stereo_basic.srcs/sources_1/imports/rtl').glob('stereo*.sv')),
                 HERE / 'sim/tb_stereo_basic.sv', HERE / 'sim/tb_frame_store.sv', HERE/'sim/tb_camera_rx.sv',
                 HERE / 'sim/tb_camera_init.sv',
                 BIN.parent/'data/verilog/src/glbl.v'])
    for name in ('stereo_basic', 'frame_store', 'camera_rx', 'camera_init'):
        run('xelab', ['tb_' + name, 'glbl', '-s', name + '_test', '-mt', '8', '-L', 'xpm', '--timescale', '1ns/1ps'])
        body = run('xsim', [name + '_test', '-tclbatch', 'run.tcl'])
        (LOGS / (name + '_result.log')).write_text(body, encoding='utf-8')
        if 'PASS ' + name not in body or 'Fatal:' in body or 'Error:' in body or 'ERROR:' in body:
            print('\n'.join(body.splitlines()[-25:]))
            return 1
        print(next(line for line in body.splitlines() if 'PASS ' + name in line))
    return 0

if __name__ == '__main__':
    raise SystemExit(main())

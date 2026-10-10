"""编译并运行 acx750 的 RTL 自检台（只用 Python 标准库）。

每个用例用 Vivado 的 xvlog + xelab + xsim 编译仿真：
    xvlog.bat -sv -i <rtl> <tb.sv> <依赖的 rtl...>
    xelab.bat -debug typical <top> -s sim_snap
    xsim.bat  sim_snap -runall
判定标准：xsim 输出里出现 "PASS" 且不出现 "FAIL"，且三步都没有
FATAL_ERROR / 非零返回码。

直接运行：
    py -3 tests/run_rtl_tests.py
可选参数：
    --tools <Vivado bin 目录>   默认 C:/Xilinx/Vivado/2018.3/bin
    --only  tb_cmd tb_reset ... 只跑指定用例
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]      # fpga_acx750
SIM = ROOT / "sim"
RTL = ROOT / "rtl"
OUT = ROOT / "tests" / "output"                 # 仿真中间产物（日志/快照）

# 用例名 -> 依赖的 RTL 源文件（相对 rtl/）
CASES = [
    ("tb_uart_loopback", ["common/acx750_uart_tx.sv",
                          "common/acx750_uart_rx.sv"]),
    ("tb_cmd",           ["common/acx750_cmd.sv"]),
    ("tb_self_pattern",  ["ddr3/acx750_self_pattern.sv"]),
    ("tb_hud_text",      ["display/acx750_hud_text.sv"]),
    ("tb_reset",         ["common/acx750_reset.sv"]),
    ("tb_uart_report",   ["common/acx750_uart_report.sv",
                          "common/acx750_uart_tx.sv",
                          "common/acx750_uart_rx.sv"]),
]


def run_step(cmd: list[str], cwd: Path, log: Path, timeout: int = 300) -> tuple[int, str]:
    """执行一步编译/仿真命令，写日志并返回 (返回码, 输出)。"""
    proc = subprocess.run(
        cmd, cwd=str(cwd), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, errors="replace", timeout=timeout,
    )
    out = proc.stdout or ""
    log.write_text(out, encoding="utf-8")
    return proc.returncode, out


def run_case(name: str, rtl_files: list[str], tools: Path) -> dict:
    work = OUT / name
    work.mkdir(parents=True, exist_ok=True)

    sources = [SIM / f"{name}.sv"] + [RTL / f for f in rtl_files]
    vlog = tools / "xvlog.bat"
    elab = tools / "xelab.bat"
    xsim = tools / "xsim.bat"

    steps = [
        ("xvlog", [str(vlog), "-sv", "-i", str(RTL), *[str(p) for p in sources]]),
        ("xelab", [str(elab), "-debug", "typical", name, "-s", "sim_snap"]),
        ("xsim",  [str(xsim), "sim_snap", "-runall"]),
    ]

    start = time.perf_counter()
    final = ""
    for index, (label, cmd) in enumerate(steps):
        code, out = run_step(cmd, work, work / f"{index}_{label}.log")
        final = out
        if code != 0 or "FATAL_ERROR" in out or "Fatal:" in out:
            return {
                "name": name, "pass": False, "seconds": round(time.perf_counter() - start, 2),
                "reason": f"{label} 失败（返回码 {code}）", "log": str(work / f"{index}_{label}.log"),
            }

    ok = ("PASS" in final) and ("FAIL" not in final)
    reason = "" if ok else (
        "未出现 PASS" if "PASS" not in final else "输出含 FAIL"
    )
    return {
        "name": name, "pass": ok, "seconds": round(time.perf_counter() - start, 2),
        "reason": reason, "log": str(work / "2_xsim.log"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="acx750 RTL 自检驱动")
    parser.add_argument("--tools", type=Path, default=Path("C:/Xilinx/Vivado/2018.3/bin"),
                        help="Vivado bin 目录（含 xvlog/xelab/xsim）")
    parser.add_argument("--only", nargs="*", help="只跑指定用例")
    args = parser.parse_args()

    for tool in ("xvlog.bat", "xelab.bat", "xsim.bat"):
        if not (args.tools / tool).exists():
            print(f"找不到 {args.tools / tool}，请用 --tools 指定 Vivado bin 目录")
            return 2

    passed = 0
    failed = 0
    for name, rtl_files in CASES:
        if args.only and name not in args.only:
            continue
        print(f"== {name} ==", flush=True)
        try:
            result = run_case(name, rtl_files, args.tools)
        except subprocess.TimeoutExpired:
            result = {"name": name, "pass": False, "seconds": 0.0,
                      "reason": "超时", "log": ""}

        if result["pass"]:
            passed += 1
            print(f"  [OK] {name}（{result['seconds']}s）", flush=True)
        else:
            failed += 1
            print(f"  [FAIL] {name}：{result['reason']}", flush=True)
            log = result.get("log")
            if log and Path(log).exists():
                tail = Path(log).read_text(encoding="utf-8", errors="replace").splitlines()
                for line in tail[-15:]:
                    print(f"      | {line}", flush=True)

    print(f"\n通过 {passed} 项，失败 {failed} 项", flush=True)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
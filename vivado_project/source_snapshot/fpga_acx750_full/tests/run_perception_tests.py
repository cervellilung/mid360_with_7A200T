"""编译并运行 acx750_full（ACX750 / XC7A200T）的 RTL 回归测试（只用 Python 标准库）。

把两套测试台合并到同一个驱动里跑：

  * 平台自检（`sim/*.sv`，6 项）—— ACX750 工程原有的 bring-up 自检台；
  * 感知核测试（`sim/perception/*.sv`，10 项）—— 从 7020
    `fpga_ac880/sensor_perception_ar/tests/` 原样搬入，被测逻辑零改动。

每个用例用 Vivado 的 xvlog + xelab + xsim 编译仿真：

    xvlog.bat -sv -i <rtl> -i <rtl/perception> <tb.sv> <依赖的 rtl...>
    xelab.bat -debug typical <tb_top> -s sim_snap
    xsim.bat  sim_snap -runall [-f arguments.txt]

判定标准：三步都没有 FATAL_ERROR / 非零返回码，且 xsim 输出里出现 "PASS"
且不出现 "FAIL"，即判该用例通过。

感知核 RTL（`rtl/perception/`）由他人并行搬运，本驱动在缺少依赖 RTL 时
**跳过**对应用例并说明原因（不算失败），因此可以先只验证平台那一组。

直接运行：

    py -3 tests/run_perception_tests.py

可选参数：

    --tools <Vivado bin 目录>       默认 C:/Xilinx/Vivado/2018.3/bin
    --only  tb_cmd tb_math ...      只跑指定用例名
    --skip-platform                 只跑感知核那一组
    --skip-perception               只跑平台那一组

中间产物（xvlog/xelab/xsim 日志、快照）写在 `tests/output/<用例名>/`，
该目录已被仓库根 `.gitignore` 的 `output/` 规则忽略，不会污染工程根目录。
"""
from __future__ import annotations

import argparse
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]        # fpga_acx750_full
SIM = ROOT / "sim"
SIM_PERCEPTION = SIM / "perception"
RTL = ROOT / "rtl"
RTL_PERCEPTION = RTL / "perception"
OUT = ROOT / "tests" / "output"                    # 仿真中间产物（被 .gitignore 覆盖）

# ---------------------------------------------------------------------------
# 平台自检用例（sim/ 下 6 个），依赖相对 rtl/
# ---------------------------------------------------------------------------
PLATFORM_CASES = [
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

# ---------------------------------------------------------------------------
# 感知核用例（sim/perception/ 下 10 个），依赖相对 rtl/perception/
#   第三列: None=普通自检; "parser"=需注入报文; "grid"=需 input/output 文件
#           （grid 的逐对象数值比对依赖 7020 的 numpy 参考模型，本驱动只做
#            编译+仿真冒烟，详见 sim/README.md）
# ---------------------------------------------------------------------------
PERCEPTION_CASES = [
    ("tb_math",        ["integer_math.sv"],                              None),
    ("tb_motion",      ["integer_math.sv", "chassis_motion.sv"],         None),
    ("tb_projector",   ["integer_math.sv", "fixed_projector.sv"],        None),
    ("tb_ar",          ["ar_video.sv"],                                  None),
    ("tb_ar_compact",  ["ar_video.sv"],                                  None),
    ("tb_hud",         ["ar_video.sv"],                                  None),
    ("tb_parser",      ["integer_math.sv", "mid360_points.sv"],          "parser"),
    ("tb_regs",        ["perception_regs.sv"],                           None),
    ("tb_engine",      ["integer_math.sv", "packet_tap.sv", "mid360_points.sv",
                        "cell_ram.sv", "lidar_grid.sv", "chassis_motion.sv",
                        "fixed_projector.sv", "ar_video.sv", "perception_engine.sv"], None),
    ("tb_grid",        ["cell_ram.sv", "lidar_grid.sv"],                 "grid"),
]


def _run_step(cmd: list[str], cwd: Path, log: Path, timeout: int = 300) -> tuple[int, str]:
    """执行一步编译/仿真命令，写日志并返回 (返回码, 输出)。"""
    proc = subprocess.run(
        cmd, cwd=str(cwd), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, errors="replace", timeout=timeout,
    )
    out = proc.stdout or ""
    log.write_text(out, encoding="utf-8")
    return proc.returncode, out


def _write_mid360_packet(path: Path) -> None:
    """生成 tb_parser 需要的 52 字节 MID-360 报文（hex 文本）。

    与 7020 驱动中 "Cartesian_type2" 的构造完全一致（纯标准库 struct+zlib）：
    2 个点，原始坐标 (100,-20,30)/(110,-20,30) → 解析后 mm 坐标
    (1000,-200,300)/(1100,-200,300)，时间戳 1e9 ns。
    """
    low = bytearray(52)
    struct.pack_into("<BHHHHBBB", low, 0, 0, 52, 4800, 2, 0, 0, 2, 0)
    struct.pack_into("<Q", low, 28, 1000000000)
    for i in range(2):
        struct.pack_into("<3hBB", low, 36 + i * 8, 100 + i * 10, -20, 30, 0, 0)
    struct.pack_into("<I", low, 24, zlib.crc32(bytes(low[28:])) & 0xFFFFFFFF)
    path.write_text(str(len(low)) + "\n" + "\n".join(f"{b:02x}" for b in low) + "\n")


def _write_grid_input(path: Path) -> None:
    """生成 tb_grid 的确定性点云输入（仅冒烟；数值比对见 7020 numpy 参考模型）。"""
    pts = [(1000, 0, 300)] * 4 + [(1100, 0, 300)] * 4
    path.write_text("".join("%d %d %d\n" % p for p in pts))


def run_case(name: str, tb_path: Path, rtl_files: list[Path], tools: Path,
             includes: list[Path], work: Path, kind: str | None = None,
             timeout: int = 300) -> dict:
    """编译并仿真单个用例，返回结果字典。"""
    work.mkdir(parents=True, exist_ok=True)

    plusargs: list[str] = []
    if kind == "parser":
        packet = work / "packet.txt"
        _write_mid360_packet(packet)
        plusargs = [f"input={packet.name}"]
    elif kind == "grid":
        gin = work / "grid_input.txt"
        _write_grid_input(gin)
        plusargs = [f"input={gin.name}", "output=grid_output.txt"]

    sources = [tb_path, *rtl_files]
    inc_args: list[str] = []
    for inc in includes:
        if inc.exists():
            inc_args += ["-i", str(inc)]

    steps = [
        ("xvlog", [str(tools / "xvlog.bat"), "-sv", *inc_args, *[str(p) for p in sources]]),
        ("xelab", [str(tools / "xelab.bat"), "-debug", "typical", name, "-s", "sim_snap"]),
    ]
    if plusargs:
        args_file = work / "arguments.txt"
        args_file.write_text("\n".join("-testplusarg " + a for a in plusargs) + "\n")
        steps.append(("xsim", [str(tools / "xsim.bat"), "sim_snap", "-runall", "-f", args_file.name]))
    else:
        steps.append(("xsim", [str(tools / "xsim.bat"), "sim_snap", "-runall"]))

    start = time.perf_counter()
    final = ""
    for index, (label, cmd) in enumerate(steps):
        try:
            code, out = _run_step(cmd, work, work / f"{index}_{label}.log", timeout)
        except subprocess.TimeoutExpired:
            return {"name": name, "pass": False, "seconds": round(time.perf_counter() - start, 2),
                    "reason": f"{label} 超时", "log": str(work / f"{index}_{label}.log")}
        final = out
        if code != 0 or "FATAL_ERROR" in out or "Fatal:" in out:
            return {"name": name, "pass": False, "seconds": round(time.perf_counter() - start, 2),
                    "reason": f"{label} 失败（返回码 {code}）", "log": str(work / f"{index}_{label}.log")}

    ok = ("PASS" in final) and ("FAIL" not in final)
    reason = "" if ok else ("未出现 PASS" if "PASS" not in final else "输出含 FAIL")
    return {"name": name, "pass": ok, "seconds": round(time.perf_counter() - start, 2),
            "reason": reason, "log": str(work / "2_xsim.log")}


def _print_failure_tail(log_path: str) -> None:
    p = Path(log_path)
    if p.exists():
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines()[-15:]:
            print(f"      | {line}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="acx750_full RTL 回归驱动（平台 + 感知核）")
    parser.add_argument("--tools", type=Path, default=Path("C:/Xilinx/Vivado/2018.3/bin"),
                        help="Vivado bin 目录（含 xvlog/xelab/xsim）")
    parser.add_argument("--only", nargs="*", help="只跑指定用例名")
    parser.add_argument("--skip-platform", action="store_true", help="只跑感知核那一组")
    parser.add_argument("--skip-perception", action="store_true", help="只跑平台那一组")
    args = parser.parse_args()

    for tool in ("xvlog.bat", "xelab.bat", "xsim.bat"):
        if not (args.tools / tool).exists():
            print(f"找不到 {args.tools / tool}，请用 --tools 指定 Vivado bin 目录")
            return 2

    passed = failed = skipped = 0
    skip_notes: list[str] = []

    # ---- 平台自检 ----
    if not args.skip_platform:
        for name, deps in PLATFORM_CASES:
            if args.only and name not in args.only:
                continue
            print(f"== {name}（平台） ==", flush=True)
            tb = SIM / f"{name}.sv"
            rtl_files = [RTL / f for f in deps]
            try:
                result = run_case(name, tb, rtl_files, args.tools, [RTL], OUT / name)
            except Exception as exc:                       # noqa: BLE001 - 汇报用
                result = {"name": name, "pass": False, "seconds": 0.0,
                          "reason": f"异常：{exc}", "log": ""}
            if result["pass"]:
                passed += 1
                print(f"  [OK] {name}（{result['seconds']}s）", flush=True)
            else:
                failed += 1
                print(f"  [FAIL] {name}：{result['reason']}", flush=True)
                if result.get("log"):
                    _print_failure_tail(result["log"])

    # ---- 感知核 ----
    if not args.skip_perception:
        for name, deps, kind in PERCEPTION_CASES:
            if args.only and name not in args.only:
                continue
            print(f"== {name}（感知核） ==", flush=True)
            tb = SIM_PERCEPTION / f"{name}.sv"
            missing = [d for d in deps if not (RTL_PERCEPTION / d).exists()]
            if not tb.exists():
                missing = ["<测试台缺失>"] + missing
            if missing:
                skipped += 1
                note = f"{name} 跳过：rtl/perception/ 缺少 {', '.join(missing)}（RTL 未就位）"
                skip_notes.append(note)
                print(f"  [SKIP] {note}", flush=True)
                continue
            rtl_files = [RTL_PERCEPTION / f for f in deps]
            try:
                result = run_case(name, tb, rtl_files, args.tools,
                                  [RTL, RTL_PERCEPTION], OUT / name, kind=kind)
            except Exception as exc:                       # noqa: BLE001 - 汇报用
                result = {"name": name, "pass": False, "seconds": 0.0,
                          "reason": f"异常：{exc}", "log": ""}
            if result["pass"]:
                passed += 1
                print(f"  [OK] {name}（{result['seconds']}s）", flush=True)
            else:
                failed += 1
                print(f"  [FAIL] {name}：{result['reason']}", flush=True)
                if result.get("log"):
                    _print_failure_tail(result["log"])

    print(f"\n通过 {passed} 项，失败 {failed} 项，跳过 {skipped} 项", flush=True)
    for note in skip_notes:
        print(f"  - {note}", flush=True)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
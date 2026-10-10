"""Bounded, receive-only ACX750 Full acceptance and deterministic replay.

This checks telemetry integrity, not physical AR alignment or sensor accuracy.
No configuration writes, UART control, JTAG or chassis commands are sent.
"""
from __future__ import annotations
import argparse
from collections import Counter
from datetime import datetime
import json
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
from . import m3tl

ROOT = Path(__file__).resolve().parents[1]


class Audit:
    def __init__(self):
        self.counts = Counter()
        self.errors = Counter()
        self.examples = []
        self.last_seq = {}
        self.latest = {}

    def error(self, reason):
        self.errors[reason] += 1
        if len(self.examples) < 8:
            self.examples.append(reason)

    def add(self, data, peer, board):
        if peer[0] != board:
            self.errors['wrong_source'] += 1
            return False
        try:
            frame, fields = m3tl.decode_message(data)
        except (ValueError, KeyError) as exc:
            self.error('invalid_packet:' + str(getattr(exc, 'reason', 'decode')))
            return False
        kind = frame.type_id
        # Unknown types are never counted as one of the required channels.
        self.counts[kind] += 1
        previous = self.last_seq.get(kind)
        if previous is not None:
            delta = (frame.sequence - previous) & 0xFFFFFFFF
            if delta == 0:
                self.error('duplicate_sequence')
            elif delta != 1:
                self.error('sequence_gap' if delta < 0x80000000 else 'reordered_or_reset')
        self.last_seq[kind] = frame.sequence
        self.latest[kind] = fields
        if kind == 1:
            if not fields['pll_locked'] or not fields['ddr3_calib_done']:
                self.error('clock_or_ddr_not_ready')
            if not fields['cam_init_done']:
                self.error('camera_not_initialized')
        elif kind == 3:
            if fields['count'] > 32:
                self.error('target_capacity')
            if fields['overflow']:
                self.error('target_overflow')
            for target in fields['targets']:
                if any(target[f'{axis}_min'] > target[f'{axis}_max'] for axis in 'xyz'):
                    self.error('inverted_target_bounds')
        elif kind == 5:
            if (fields['rows'], fields['cols'], fields['cell_mm']) != (55, 60, 100):
                self.error('grid_contract')
            # 3300 cells use four bits of the last byte; unused bits must be zero.
            used_bits = (fields['rows'] * fields['cols']) % 8
            padding_mask = (0xFF << used_bits) & 0xFF if used_bits else 0
            bitmap = bytes.fromhex(fields['bitmap_hex'])
            if bitmap and bitmap[-1] & padding_mask:
                self.error('grid_padding_bits')
        return True

    def report(self, required):
        missing = sorted(set(required) - self.counts.keys())
        return {
            'scope': 'telemetry_integrity_only',
            'status': 'pass' if not missing and not self.errors else 'fail',
            'messages': dict(self.counts), 'missing_types': missing,
            'errors': dict(self.errors), 'error_examples': self.examples,
            'latest': self.latest,
            'ar_visual': 'pending_user_observation',
            'measurement_accuracy': 'not_tested', 'chassis': 'deferred',
            'camera_status_note': 'frames is a pixel counter in the current Full RTL; last_frame_ms is a placeholder',
        }



def check_continuity(result, heartbeat_times, duration, max_gap_s=3.0):
    """Require periodic heartbeat to continue through the observation end.

    Initial silence is handled by startup/physical reset separately. Missing
    heartbeat already fails the channel audit; do not fabricate an age for it.
    """
    gaps = [b-a for a,b in zip(heartbeat_times, heartbeat_times[1:])]
    tail = duration-heartbeat_times[-1] if heartbeat_times else None
    worst = max(gaps + ([tail] if tail is not None else []), default=0)
    result['continuity'] = {'heartbeat_timeout_s': max_gap_s,
                            'last_heartbeat_s': heartbeat_times[-1] if heartbeat_times else None,
                            'tail_s': tail, 'max_gap_s': worst,
                            'observation_duration_s': duration}
    if heartbeat_times and worst > max_gap_s:
        result['errors']['heartbeat_stream_stalled'] = 1
        result['status'] = 'fail'
    return result


def receive(bind, port, board, duration, grace, out):
    if not 0 < duration <= 120 or not 0 <= grace < duration:
        raise ValueError('Require 0 <= startup grace < duration <= 120 seconds')
    out.mkdir(parents=True, exist_ok=False)
    audit = Audit()
    heartbeat_times = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
        sock.bind((bind, port))
        start = time.monotonic()
        sock.settimeout(min(.2, duration))
        first = None
        with (out / 'telemetry_wire.jsonl').open('w', encoding='utf-8') as log:
            while time.monotonic() - start < duration:
                try:
                    packet, peer = sock.recvfrom(65535)
                except socket.timeout:
                    continue
                age = time.monotonic() - start
                # The settling window remains recorded for diagnosis. Sequence
                # and readiness acceptance begins after the 12-second startup.
                accepted = age >= grace
                if peer[0] == board and first is None:
                    first = age
                log.write(json.dumps({'elapsed_s': age, 'peer': list(peer),
                                      'acceptance_window': accepted,
                                      'wire_hex': packet.hex()}) + '\n')
                if accepted:
                    if audit.add(packet, peer, board) and packet[5] == 1:
                        heartbeat_times.append(age)
    result = check_continuity(audit.report((1, 3, 5, 6)), heartbeat_times, duration)
    result.update(duration_s=duration, startup_grace_s=grace,
                  first_packet_s=first, board=board, mode='live_passive',
                  loaded_image='not_verified_by_UDP')
    (out / 'summary.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    return result


def replay(path, board):
    audit = Audit()
    heartbeat_times = []
    last_elapsed = 0.0
    with Path(path).open(encoding='utf-8') as source:
        for line in source:
            row = json.loads(line)
            last_elapsed = float(row['elapsed_s'])
            if row['acceptance_window']:
                data = bytes.fromhex(row['wire_hex'])
                if audit.add(data, row['peer'], board) and data[5] == 1:
                    heartbeat_times.append(last_elapsed)
    result = audit.report((1, 3, 5, 6))
    summary = Path(path).with_name('summary.json')
    if summary.exists():
        metadata = json.loads(summary.read_text(encoding='utf-8'))
        result = check_continuity(result, heartbeat_times, metadata['duration_s'])
    else:
        result['continuity'] = {'status': 'unknown_without_observation_duration'}
    result['mode'] = 'replay'
    return result


def preflight():
    checks = []
    capture = ROOT / 'results/linux_host_20261007/accepted_candidate/candidate.json'
    checker = ROOT / ('tools/software/check_capture_candidate.py' if capture.exists() else 'tools/software/check_hdmi_candidate.py')
    arguments = [sys.executable, str(checker)] + ([] if capture.exists() else ['--project', 'acx750_full'])
    run = subprocess.run(arguments,
                         capture_output=True, text=True, errors='replace', timeout=30)
    checks.append({'name': 'candidate_hash_timing_drc', 'pass': run.returncode == 0,
                   'detail': (run.stdout + run.stderr)[-1000:]})
    imp = ROOT / 'vivado_project/acx750_full/acx750_full.srcs/sources_1/imports'
    top = (imp / 'rtl/acx750_full_top.sv').read_bytes().decode('gbk')
    match = re.search(r'camera_init\s*#\((.*?)\)\s*u_cam_init', top, re.S)
    camera_clock = bool(match and re.search(r'\.SYS_CLOCK\s*\(\s*100_000_000\s*\)', match[1]))
    checks.append({'name': 'camera_init_actual_100MHz', 'pass': camera_clock,
                   'detail': 'Requires the camera-specific parameter; another I2C instance does not count.'})
    xci = (ROOT / 'vivado_project/acx750_full/acx750_full.srcs/sources_1/ip/'
           'eth_phase_mmcm/eth_phase_mmcm.xci').read_text(encoding='utf-8')
    params = {}
    for key, value in re.findall(r'referenceId="PARAM_VALUE\.([^"]+)"[^>]*>([^<]*)', xci):
        if value.strip():
            params[key] = value.strip()
    clock_ok = (params.get('CLKOUT1_REQUESTED_PHASE') in ('270', '270.000') and
                params.get('CLKOUT1_DRIVES') == 'BUFG' and
                params.get('FEEDBACK_SOURCE') == 'FDBK_AUTO' and
                params.get('CLKOUT2_USED') == 'false' and
                'assign clk125m = rgmii_rx_clk;' in top and
                'BUFG u_bufg_eth' not in top)
    checks.append({'name': 'validated_RX_clock_configuration', 'pass': clock_ok,
                   'detail': '270-degree RX, automatic feedback, one global output; built MMCM must also pass the implementation gate.'})
    for name, label in (('eth/acx750_arp_reply.sv', 'validated_host_MAC_learning_source'),
                        ('eth_mdio/phy_reg_config.v', 'validated_PHY_RX_delay_source')):
        full = imp / name
        reference = ROOT / 'vivado_project/acx750/acx750.srcs/sources_1/imports' / name
        same = full.exists() and reference.exists() and full.read_bytes() == reference.read_bytes()
        checks.append({'name': label, 'pass': same,
                       'detail': 'A difference requires explicit review; not automatically a functional failure.'})
    return {'mode': 'preflight', 'status': 'pass' if all(x['pass'] for x in checks) else 'blocked',
            'checks': checks, 'board_programmed': False,
            'validation_scope': 'experimental_bringup_candidate',
            'limitations': ['External IO delay constraints and physical setup/hold margins require separate signoff.',
                            'Candidate integrity does not prove camera, radar, AR or latency on hardware.'],
            'next': ('Explicit temporary JTAG load, then passive capture; hardware validation remains pending.'
                     if all(x['pass'] for x in checks) else
                     'Review failed checks and rebuild before JTAG; do not overwrite another task.')}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=('preflight', 'listen', 'replay'), default='preflight')
    parser.add_argument('--bind', default='192.168.1.10')
    parser.add_argument('--port', type=int, default=46000)
    parser.add_argument('--board', default='192.168.1.50')
    parser.add_argument('--duration', type=float, default=30)
    parser.add_argument('--startup-grace', type=float, default=12)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--recording', type=Path)
    args = parser.parse_args(argv)
    try:
        if args.mode == 'listen':
            out = args.output or ROOT / 'sample/board_tests' / ('full_' + datetime.now().strftime('%Y%m%d_%H%M%S'))
            result = receive(args.bind, args.port, args.board, args.duration, args.startup_grace, out)
            print('EVIDENCE', out)
        elif args.mode == 'replay':
            if args.recording is None:
                parser.error('--recording is required for replay')
            result = replay(args.recording, args.board)
        else:
            result = preflight()
            if args.output:
                args.output.mkdir(parents=True, exist_ok=False)
                (args.output/'summary.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        brief = {k: v for k, v in result.items() if k != 'latest'}
        print(json.dumps(brief, ensure_ascii=True))
        return 0 if result['status'] == 'pass' else 2
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print(json.dumps({'status': 'error', 'reason': str(exc)}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())

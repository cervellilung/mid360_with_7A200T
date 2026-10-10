"""Recorded radar input shared by mesh and AR previews."""
import numpy as np
from web_server.ar_render.m3cp_recording import StreamFile
from web_server.pc_perception.protocol import PacketError, decode_mid360

def collect_points(radar: StreamFile, centre_us: int, half_window_us: int) -> tuple[np.ndarray, int, int]:
    """Accumulate every decodable MID-360 packet in a time window."""
    low, high = radar.window(centre_us - half_window_us, centre_us + half_window_us)
    chunks: list[np.ndarray] = []
    decoded = bad = 0
    for index in range(low, high):
        try:
            packet = decode_mid360(radar.payload(index))
        except PacketError:
            bad += 1
            continue
        points = packet.points
        chunks.append(np.stack([points["x"], points["y"], points["z"]], axis=1).astype(np.int64))
        decoded += 1
    if not chunks:
        return np.zeros((0, 3), np.int64), decoded, bad
    return np.concatenate(chunks, axis=0), decoded, bad



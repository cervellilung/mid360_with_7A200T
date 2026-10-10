"""Single processing path for synthetic, recorded, and explicit live input."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import time

import numpy as np

from .frame import FrameAssembler, Scan
from .grid import Detection, GridConfig, GridProcessor, GridResult
from .odom import DFLinkStream, IntegerAttitude, Odom, Attitude
from .projection import Calibration, project_box
from .protocol import PacketError, decode_mid360
from .session import Event, RADAR, CAMERA, ODOM, SessionWriter
from .sources import decode_camera


STALE_NS = 150_000_000
CAMERA_STALE_NS = 500_000_000
RADAR_STARTUP_GRACE_NS = 12_000_000_000


@dataclass
class Statistics:
    radar_packets: int = 0
    bad_radar_packets: int = 0
    radar_packets_without_crc: int = 0
    scans: int = 0
    dropped_points: int = 0
    missed_packets: int = 0
    camera_frames: int = 0
    odom_frames: int = 0
    processing_ns_total: int = 0


class PerceptionPipeline:
    def __init__(self, config: GridConfig | None = None,
                 calibration: Calibration | None = None,
                 camera_id: str = "", mount_id: str = "",
                 recorder: SessionWriter | None = None,
                 time_offset_ns: int | None = None):
        self.grid = GridProcessor(config)
        self.assembler = FrameAssembler(self.grid.config.max_points)
        self.calibration = calibration
        self.camera_id, self.mount_id = camera_id, mount_id
        self.recorder = recorder
        self.time_offset_ns = time_offset_ns
        self.df = DFLinkStream()
        self.attitude = IntegerAttitude()
        self.latest_attitude = Attitude(0, 0, 0)
        self.latest_odom: Odom | None = None
        self.latest_result: GridResult | None = None
        self.latest_scan_host_ns = 0
        self.latest_camera_ns = 0
        self.latest_frame: np.ndarray | None = None
        self.stats = Statistics()
        self.track_next_id = 1
        self.tracks: list[Detection] = []
        self.created_ns = time.monotonic_ns()

    def ingest(self, event: Event) -> None:
        if self.recorder:
            self.recorder.write(event)
        if event.kind == RADAR:
            try:
                packet = decode_mid360(event.payload, event.host_ns)
            except PacketError:
                self.stats.bad_radar_packets += 1
                return
            self.stats.radar_packets += 1
            if not packet.crc_present:
                self.stats.radar_packets_without_crc += 1
            if scan := self.assembler.add(packet):
                self._process_scan(scan)
        elif event.kind == CAMERA:
            self.latest_frame = decode_camera(event.payload)
            self.latest_camera_ns = event.host_ns
            self.stats.camera_frames += 1
        elif event.kind == ODOM:
            for odom in self.df.feed(event.payload, event.host_ns):
                self.latest_odom = odom
                self.latest_attitude = self.attitude.update(odom)
                self.stats.odom_frames += 1

    def finish(self, flush_partial: bool = True) -> None:
        if scan := self.assembler.flush():
            if flush_partial:
                self._process_scan(scan)
        if self.recorder:
            self.recorder.close()

    def _process_scan(self, scan: Scan) -> None:
        started = time.perf_counter_ns()
        result = self.grid.process(scan.points)
        self.stats.processing_ns_total += time.perf_counter_ns()-started
        self.stats.scans += 1
        self.stats.dropped_points += scan.dropped_points + result.overflow_points
        self.stats.missed_packets += scan.missed_packets
        self.latest_scan_host_ns = (scan.device_ns + self.time_offset_ns
                                    if self.time_offset_ns is not None else scan.host_ns)
        self.latest_result = result
        self.tracks = self._track(result.detections)

    def _track(self, detections: tuple[Detection, ...]) -> list[Detection]:
        previous = self.tracks
        taken: set[int] = set()
        output = []
        for d in detections:
            center = tuple((a+b)//2 for a, b in zip(d.min_xyz_mm, d.max_xyz_mm))
            candidates = []
            for old in previous:
                if old.object_id in taken:
                    continue
                old_center = tuple((a+b)//2 for a, b in zip(old.min_xyz_mm, old.max_xyz_mm))
                dsq = sum((center[k]-old_center[k])**2 for k in range(2))
                if dsq <= 500*500:
                    candidates.append((dsq, old.object_id))
            if candidates:
                object_id = min(candidates)[1]
            else:
                object_id = self.track_next_id
                self.track_next_id += 1
            taken.add(object_id)
            output.append(Detection(object_id, d.cells, d.points, d.min_xyz_mm,
                                    d.max_xyz_mm, d.closest_xyz_mm, d.nearest_xy_sq_mm2))
        return output

    def status(self, now_ns: int) -> dict:
        frame = self.latest_frame
        camera_ok = frame is not None and 0 <= now_ns-self.latest_camera_ns <= CAMERA_STALE_NS
        scan_age = now_ns-self.latest_scan_host_ns if self.latest_scan_host_ns else None
        radar_ok = scan_age is not None and 0 <= scan_age <= STALE_NS
        uptime_ns = now_ns - self.created_ns
        radar_starting = (self.stats.radar_packets == 0 and
                          0 <= uptime_ns <= RADAR_STARTUP_GRACE_NS)
        cal_ok = bool(camera_ok and self.calibration and
                      self.calibration.compatible(frame.shape[1], frame.shape[0],
                                                  self.camera_id, self.mount_id))
        return {"camera_ok": camera_ok, "radar_ok": radar_ok,
                "radar_starting": radar_starting,
                "calibrated": cal_ok, "scan_age_ms": None if scan_age is None else scan_age//1_000_000,
                "objects": len(self.tracks) if radar_ok else 0,
                "stats": asdict(self.stats)}

    def render(self, now_ns: int) -> tuple[np.ndarray, np.ndarray, dict]:
        """OpenCV is only the display backend; all detection remains integer core."""
        import cv2
        status = self.status(now_ns)
        if status["camera_ok"]:
            video = self.latest_frame.copy()
        else:
            video = np.zeros((480, 640, 3), np.uint8)
            cv2.putText(video, "CAMERA DISCONNECTED", (25, 45), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
        if self.latest_result is None:
            bev = np.zeros((550, 600, 3), np.uint8)
        else:
            counts = self.latest_result.grid_counts
            # Front (LiDAR +x) is up; left (+y) is left in the displayed BEV.
            oriented = counts.T[::-1, ::-1].copy()
            intensity = np.minimum(oriented.astype(np.uint16)*30, 255).astype(np.uint8)
            bev = cv2.resize(cv2.applyColorMap(intensity, cv2.COLORMAP_TURBO), (600, 550),
                             interpolation=cv2.INTER_NEAREST)
        c = self.grid.config
        if status["radar_ok"]:
            for det in self.tracks:
                lo, hi = det.min_xyz_mm, det.max_xyz_mm
                x0 = max(0, min(599, (c.y_max_mm-1-hi[1])*600//(c.y_max_mm-c.y_min_mm)))
                x1 = max(0, min(599, (c.y_max_mm-1-lo[1])*600//(c.y_max_mm-c.y_min_mm)))
                y0 = max(0, min(549, (c.x_max_mm-1-hi[0])*550//(c.x_max_mm-c.x_min_mm)))
                y1 = max(0, min(549, (c.x_max_mm-1-lo[0])*550//(c.x_max_mm-c.x_min_mm)))
                cv2.rectangle(bev, (x0, y0), (max(x0+2, x1), max(y0+2, y1)), (255, 255, 255), 2)
                cv2.putText(bev, f"#{det.object_id} {det.distance_mm/1000:.2f}m",
                            (x0, max(18, y0-5)), cv2.FONT_HERSHEY_SIMPLEX, 0.48,
                            (255, 255, 255), 1)
        cv2.putText(bev, "FRONT +X", (8, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
        cv2.putText(bev, "LEFT +Y", (8, 538), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
        cv2.putText(bev, "RIGHT -Y", (487, 538), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
        if status["radar_ok"]:
            for det in self.tracks:
                d = det.distance_mm
                color = (0, 0, 255) if d < 1000 else ((0, 255, 255) if d < 2000 else (0, 255, 0))
                if status["calibrated"]:
                    box = project_box(det, self.calibration)
                    if box is not None:
                        cv2.rectangle(video, box[:2], box[2:], color, 2)
                        cv2.putText(video, f"#{det.object_id} {d/1000:.2f}m", (box[0], max(20, box[1]-8)),
                                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 2)
            nearest = min((d.distance_mm for d in self.tracks), default=None)
            label = "NO DETECTION" if nearest is None else f"NEAREST {nearest/1000:.2f} m"
            if not status["calibrated"]:
                label += "  UNCALIBRATED"
        else:
            label = "RADAR STALE / DISCONNECTED"
        cv2.rectangle(video, (0, 0), (video.shape[1], 34), (20, 20, 20), -1)
        cv2.putText(video, label, (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 2)
        if self.latest_odom is not None:
            yaw_deg = self.latest_attitude.yaw_q16*180/(65536*3.141592653589793)
            cv2.putText(video, f"YAW {yaw_deg:.1f} deg", (8, video.shape[0]-10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
        return video, bev, status

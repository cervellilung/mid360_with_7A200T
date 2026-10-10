from __future__ import annotations

import json
from pathlib import Path
import struct
import tempfile
import unittest

import numpy as np

from pc_perception.calibration import estimate_time_offset, fit_ground_plane
from pc_perception.frame import FrameAssembler
from pc_perception.grid import GridConfig, GridProcessor
from pc_perception.odom import DFLinkStream, IntegerAttitude, build_odom_subscription
from pc_perception.pipeline import PerceptionPipeline
from pc_perception.projection import project_box, project_point
from pc_perception.protocol import (POINT_DTYPE, PacketError, decode_mid360,
                                    encode_mid360_for_test)
from pc_perception.session import Event, SessionReader, SessionWriter, RADAR, ODOM
from pc_perception.sources import SyntheticSource, make_synthetic_odom
from pc_perception.vectors import export_vectors, synthetic_calibration


def points_from_xyz(xyz):
    pts = np.zeros(len(xyz), POINT_DTYPE)
    for i, value in enumerate(xyz):
        pts[i]["x"], pts[i]["y"], pts[i]["z"] = value
    return pts


class ProtocolTests(unittest.TestCase):
    def test_valid_crc_and_corruption(self):
        raw = encode_mid360_for_test(points_from_xyz([(1000, 0, 300)]), 123456)
        decoded = decode_mid360(raw, 987)
        self.assertEqual((len(decoded.points), decoded.timestamp_ns, decoded.host_ns), (1, 123456, 987))
        self.assertTrue(decoded.crc_present)
        bad = bytearray(raw)
        bad[-1] ^= 1
        with self.assertRaisesRegex(PacketError, "CRC32"):
            decode_mid360(bytes(bad))
        with self.assertRaisesRegex(PacketError, "length"):
            decode_mid360(raw[:-1])

    def test_zero_crc_field_is_reported_as_missing(self):
        raw = bytearray(encode_mid360_for_test(points_from_xyz([(1000, 0, 300)]), 1))
        struct.pack_into("<I", raw, 24, 0)
        decoded = decode_mid360(bytes(raw))
        self.assertFalse(decoded.crc_present)

    def test_recorded_experimental_packet_if_present(self):
        path = Path(__file__).resolve().parents[1] / "data" / "raw_packets.bin"
        if not path.exists():
            self.skipTest("optional experimental capture absent")
        raw = path.read_bytes()
        size = struct.unpack_from("<H", raw)[0]
        packet = decode_mid360(raw[2:2+size])
        self.assertEqual(len(packet.points), 96)
        self.assertFalse(packet.crc_present)


class GridTests(unittest.TestCase):
    def test_two_clusters_and_projection(self):
        result = GridProcessor().process(SyntheticSource.scan_points(0))
        self.assertEqual(len(result.detections), 2)
        self.assertEqual(result.accepted_points, 192)
        self.assertTrue(all(d.cells >= 2 and d.points == 96 for d in result.detections))
        cal = synthetic_calibration()
        self.assertIsNotNone(project_box(result.detections[0], cal))
        self.assertTrue(cal.compatible(640, 480, "synthetic", "synthetic"))
        self.assertFalse(cal.compatible(640, 480, "another camera", "synthetic"))

    def test_roi_edges_ground_and_same_cell_saturation(self):
        points = points_from_xyz([(500, -3000, 101)]*300 +
                                 [(5999, 2999, 101)]*8 +
                                 [(6000, 0, 500)] + [(500, -3000, 100)])
        result = GridProcessor().process(points)
        self.assertEqual(result.accepted_points, 308)
        self.assertEqual((result.rejected_roi, result.rejected_ground), (1, 1))
        self.assertEqual(int(result.grid_counts[0, 0]), 255)
        self.assertEqual(int(result.grid_counts[-1, -1]), 8)

    def test_overflow_and_max_32_objects(self):
        pts = points_from_xyz([(1000, 0, 300)]*40_001)
        result = GridProcessor().process(pts)
        self.assertEqual(result.overflow_points, 1)
        self.assertEqual(result.input_points, 40_001)
        # 33 disconnected 2-cell regions, each with 8 points.
        xyz = []
        for region in range(33):
            x = 500 + (region % 11)*400
            y = -3000 + (region // 11)*400
            xyz.extend([(x, y, 300)]*4 + [(x+100, y, 300)]*4)
        self.assertEqual(len(GridProcessor().process(points_from_xyz(xyz)).detections), 32)

    def test_single_hit_bridge_does_not_merge_dense_regions(self):
        xyz = ([(1000, 0, 300)]*4 + [(1100, 0, 300)]*4 +
               [(x, 0, 300) for x in (1200, 1300, 1400, 1500)] +
               [(1600, 0, 300)]*4 + [(1700, 0, 300)]*4)
        result = GridProcessor().process(points_from_xyz(xyz))
        self.assertEqual(len(result.detections), 2)
        self.assertEqual([d.cells for d in result.detections], [2, 2])
        self.assertEqual([d.points for d in result.detections], [8, 8])

    def test_isolated_sparse_eight_hit_target_survives(self):
        xyz = [(2000 + i*100, 1000, 300) for i in range(8)]
        result = GridProcessor().process(points_from_xyz(xyz))
        self.assertEqual(len(result.detections), 1)
        self.assertEqual((result.detections[0].cells, result.detections[0].points), (8, 8))

    def test_frame_assembler_bounds(self):
        assembler = FrameAssembler(max_points=100)
        one = encode_mid360_for_test(points_from_xyz([(1000, 0, 300)]*96), 10)
        two = encode_mid360_for_test(points_from_xyz([(1100, 0, 300)]*96), 480_010, 1)
        three = encode_mid360_for_test(points_from_xyz([(1200, 0, 300)]), 100_000_010, 2)
        assembler.add(decode_mid360(one, 1000))
        assembler.add(decode_mid360(two, 2000))
        ready = assembler.add(decode_mid360(three, 3000))
        self.assertEqual((len(ready.points), ready.dropped_points), (100, 92))


class OdomTests(unittest.TestCase):
    def test_odom_frame_and_integer_attitude(self):
        self.assertEqual(build_odom_subscription().hex(), "df0197048002010afd0503")
        frame = make_synthetic_odom(1_000_000_000)
        parser = DFLinkStream()
        self.assertEqual(parser.feed(frame[:17], 1_000_000_000), [])
        odom = parser.feed(frame[17:], 1_000_000_000)[0]
        self.assertEqual(odom.acceleration_raw, (0, 0, 4000))
        attitude = IntegerAttitude()
        self.assertLess(abs(attitude.update(odom).roll_q16), 10)


class RecordingTests(unittest.TestCase):
    def test_timed_capture_keeps_last_complete_scan(self):
        points = SyntheticSource.scan_points(0)
        complete = encode_mid360_for_test(points[:96], 10)
        partial = encode_mid360_for_test(points[96:97], 100_000_010, 1)
        pipeline = PerceptionPipeline()
        pipeline.ingest(Event(RADAR, 1_000_000_000, complete))
        pipeline.ingest(Event(RADAR, 1_100_000_000, partial))
        pipeline.finish(flush_partial=False)
        self.assertEqual(pipeline.stats.scans, 1)
        self.assertEqual(pipeline.latest_result.accepted_points, 96)
        self.assertEqual(len(pipeline.latest_result.detections), 1)

    def test_record_replay_and_pipeline_match(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / "session"
            pts = SyntheticSource.scan_points(0)
            events = []
            for index in range(3):
                for sub in range(2):
                    events.append(Event(RADAR, 1_000_000_000+index*100_000_000+sub*480_000,
                        encode_mid360_for_test(pts[sub*96:(sub+1)*96], index*100_000_000+sub*480_000,
                                               index*2+sub)))
            with SessionWriter(directory, {"test": True}) as writer:
                for event in events:
                    writer.write(event)
            self.assertEqual(list(SessionReader(directory)), events)
            a, b = PerceptionPipeline(), PerceptionPipeline()
            for event in events:
                a.ingest(event)
            for event in SessionReader(directory):
                b.ingest(event)
            a.finish(); b.finish()
            self.assertEqual(a.stats.scans, b.stats.scans)
            self.assertEqual(a.stats.radar_packets, b.stats.radar_packets)
            self.assertEqual(a.tracks, b.tracks)
            self.assertFalse(a.status(2_000_000_000)["radar_ok"])

    def test_calibration_math_and_vectors(self):
        pts = np.array([[x, y, 100] for x in range(0, 500, 100)
                        for y in range(0, 500, 100)], np.int32)
        plane = fit_ground_plane(pts)
        self.assertAlmostEqual(plane["plane_d_mm"], -100, delta=1)
        pairs = [{"host_ns": 1000+i*100+40, "device_ns": i*100} for i in range(20)]
        self.assertEqual(estimate_time_offset(pairs)["host_minus_device_ns"], 1040)
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)/"vectors.json"
            exported = export_vectors(out)
            self.assertEqual(json.loads(out.read_text())["sha256_without_hash"],
                             exported["sha256_without_hash"])


if __name__ == "__main__":
    unittest.main()

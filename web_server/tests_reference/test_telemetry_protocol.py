import unittest

from pc_telemetry.protocol import (
    CAMERA_STATUS,
    CHASSIS,
    HEARTBEAT,
    TARGET,
    TARGETS_HEAD,
    FrameError,
    MessageType,
    decode_frame,
    encode_frame,
    parse_payload,
)
from pc_telemetry.receiver import SequenceTracker


class TelemetryProtocolTests(unittest.TestCase):
    def roundtrip(self, message_type, payload):
        encoded = encode_frame(message_type, payload, 17, 123456)
        frame = decode_frame(encoded)
        self.assertEqual(frame.message_type, message_type)
        self.assertEqual(frame.sequence, 17)
        self.assertEqual(frame.timestamp_ms, 123456)
        self.assertEqual(frame.payload, payload)
        return parse_payload(frame)

    def test_all_payloads_roundtrip(self):
        self.assertEqual(self.roundtrip(MessageType.HEARTBEAT, HEARTBEAT.pack(1000, 9, 1, 2, 0x20260923))["tx_ok"], 9)
        chassis = CHASSIS.pack(1, 3, 0, -123, 500, -250, 4, 1200, -900, 777)
        self.assertEqual(self.roundtrip(MessageType.CHASSIS, chassis)["yaw_q10000"], -123)
        targets = TARGETS_HEAD.pack(2, 0, 0) + TARGET.pack(1, 0, 500, 700, -200, 100, 50, 800, 550) + TARGET.pack(2, 1, 900, 1100, 250, 450, 0, 600, 950)
        self.assertEqual(self.roundtrip(MessageType.TARGETS, targets)["count"], 2)
        camera = CAMERA_STATUS.pack(1, 0, 800, 480, 300, 42, 0)
        self.assertEqual(self.roundtrip(MessageType.CAMERA_STATUS, camera)["width"], 800)

    def test_crc_and_length_rejection(self):
        frame = bytearray(encode_frame(MessageType.HEARTBEAT, HEARTBEAT.pack(1, 2, 3, 4, 5), 1, 2))
        for index in (0, 24, 32):
            broken = frame.copy()
            broken[index] ^= 1
            with self.assertRaises(FrameError):
                decode_frame(bytes(broken))
        with self.assertRaises(FrameError):
            decode_frame(bytes(frame[:-1]))
        with self.assertRaises(FrameError):
            decode_frame(bytes(frame + b"x"))

    def test_target_limits(self):
        payload = TARGETS_HEAD.pack(32, 0, 0) + bytes(TARGET.size * 32)
        self.assertEqual(parse_payload(decode_frame(encode_frame(MessageType.TARGETS, payload, 0, 0)))["count"], 32)
        bad = TARGETS_HEAD.pack(33, 0, 0) + bytes(TARGET.size * 33)
        with self.assertRaises(FrameError):
            parse_payload(decode_frame(encode_frame(MessageType.TARGETS, bad, 0, 0)))

    def test_sequence_wrap_and_loss(self):
        tracker = SequenceTracker()
        tracker.observe(1, 0xFFFFFFFF)
        tracker.observe(1, 0)
        tracker.observe(1, 3)
        self.assertEqual(tracker.missing, 2)
        self.assertEqual(tracker.out_of_order, 0)


if __name__ == "__main__":
    unittest.main()


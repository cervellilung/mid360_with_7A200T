"""Original M3CP streams unchanged; separate M3PR-v1 result stream on 46104."""
import struct
import zlib
from raw_m3cp import wire as raw
from perception_model import decode_snapshot

PORTS = {**raw.PORTS, 4: 46104}
MAX_PAYLOAD = {**raw.MAX_PAYLOAD, 4: 1664}
HEADER = raw.HEADER
Record = raw.Record

def header(data, expected):
    if expected != 4:
        return raw.decode_header(data, expected)
    if len(data) != 48:
        raise raw.FrameError('short result header')
    magic, version, kind, flags, seq, boot, stamp, device, n, crc, hc = HEADER.unpack(data)
    if (magic, version, kind, n) != (b'M3PR', 1, 4, 1664):
        raise raw.FrameError('invalid M3PR version/type/length')
    if zlib.crc32(data[:44]) & 0xffffffff != hc:
        raise raw.FrameError('result header CRC mismatch')
    return kind, flags, seq, boot, stamp, device, n, crc

def encode(record):
    if record.kind != 4:
        return raw.encode(record)
    decode_snapshot(record.payload)
    prefix = struct.pack('<4sBBHIQQQII', b'M3PR', 1, 4, record.flags,
                         record.sequence, record.boot_id, record.capture_us,
                         record.device_us, len(record.payload), zlib.crc32(record.payload)&0xffffffff)
    return prefix + struct.pack('<I', zlib.crc32(prefix)&0xffffffff) + record.payload

def decode(data, expected):
    if expected != 4:
        return raw.decode(data, expected)
    kind, flags, seq, boot, stamp, device, n, crc = header(data[:48], expected)
    payload = data[48:]
    if len(payload) != n or zlib.crc32(payload)&0xffffffff != crc:
        raise raw.FrameError('result payload length/CRC mismatch')
    decode_snapshot(payload)
    return Record(kind, flags, seq, boot, stamp, device, payload)

def read_record(stream, kind):
    h = stream.read(48)
    if not h:
        return None
    fields = header(h, kind)
    return decode(h+stream.read(fields[6]), kind)

"""Segmented recording; low disk space stops recording, never deletes old files."""
from pathlib import Path
import json
import shutil
import threading
import time

class Segments:
    def __init__(self, directory, seconds=60, max_bytes=256*1024**2,
                 reserve_bytes=1024**3, free_bytes=None):
        self.root = Path(directory)
        self.root.mkdir(parents=True, exist_ok=True)
        self.seconds, self.max_bytes, self.reserve = seconds, max_bytes, reserve_bytes
        self.free = free_bytes or (lambda: shutil.disk_usage(self.root).free)
        self.lock = threading.Lock()
        self.files, self.boots, self.index = {}, {}, 0
        self.bytes = 0
        self.started = time.monotonic()
        self.status = 'ready'
        self.current = None
        self.counts = {}
        self.disabled = False

    def _close(self):
        for f in self.files.values():
            try:
                f.flush()
            except OSError:
                self.status='disk_write_error_recording_stopped'
                self.disabled=True
            finally:
                try:f.close()
                except OSError:pass
        self.files.clear()
        if self.current:
            tmp = self.current/'report.tmp'
            try:
                tmp.write_text(json.dumps({'records': self.counts, 'bytes': self.bytes,
                                           'boot_ids': self.boots, 'status': self.status}, indent=2))
                tmp.replace(self.current/'report.json')
            except OSError:
                self.status='disk_report_write_error'
                self.disabled=True

    def write(self, record, packet):
        with self.lock:
            if self.disabled:
                return False
            if self.free() < self.reserve + len(packet):
                self.status = 'disk_low_recording_stopped'
                self.disabled = True
                self._close()
                return False
            rotate = (self.current is None or time.monotonic()-self.started>=self.seconds
                      or self.bytes+len(packet)>self.max_bytes
                      or (record.kind in self.boots and self.boots[record.kind]!=record.boot_id))
            if rotate:
                self._close()
                self.index += 1
                self.current = self.root/f'segment_{self.index:06d}'
                # Never overwrite a previous run.
                while self.current.exists():
                    self.index += 1
                    self.current = self.root/f'segment_{self.index:06d}'
                self.current.mkdir()
                self.started, self.bytes, self.boots, self.counts = time.monotonic(), 0, {}, {}
            self.status = 'recording'
            if record.kind not in self.files:
                self.files[record.kind] = (self.current/f'stream_{record.kind}.bin').open('xb')
            try:
                self.files[record.kind].write(packet)
            except OSError:
                self.status = 'disk_write_error_recording_stopped'
                self.disabled = True
                self._close()
                return False
            self.boots[record.kind] = record.boot_id
            self.counts[record.kind] = self.counts.get(record.kind, 0)+1
            self.bytes += len(packet)
            return True

    def close(self):
        with self.lock:
            self._close()

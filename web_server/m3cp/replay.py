"""CRC-checked, bounded-memory chronological replay of a recording or segment root.
Playback is a separate process that sends identical records to the receiver.
"""
from pathlib import Path
import argparse
import heapq
import socket
import time
from . import wire

def records(directory):
    directory=Path(directory)
    segments=sorted(directory.glob('segment_*')) or [directory]
    for segment in segments:
        streams={}
        try:
            heads=[]
            for kind in wire.PORTS:
                path=segment/f'stream_{kind}.bin'
                if path.exists():
                    streams[kind]=path.open('rb')
                    rec=wire.read_record(streams[kind],kind)
                    if rec:heapq.heappush(heads,(rec.capture_us,kind,rec))
            while heads:
                _,kind,rec=heapq.heappop(heads)
                yield rec
                next_rec=wire.read_record(streams[kind],kind)
                if next_rec:heapq.heappush(heads,(next_rec.capture_us,kind,next_rec))
        finally:
            for f in streams.values():f.close()

def main():
    p=argparse.ArgumentParser();p.add_argument('directory',type=Path);p.add_argument('--host',default='127.0.0.1')
    p.add_argument('--speed',type=float,default=1);p.add_argument('--start',type=float,default=0)
    p.add_argument('--duration',type=float);a=p.parse_args()
    if a.speed<=0 or a.start<0:p.error('speed must be positive and start nonnegative')
    peers={};first=None;start=time.monotonic()
    try:
        for rec in records(a.directory):
            if first is None:first=rec.capture_us
            offset=(rec.capture_us-first)/1e6
            if offset<a.start:continue
            if a.duration is not None and offset>a.start+a.duration:break
            delay=(offset-a.start)/a.speed-(time.monotonic()-start)
            if delay>0:time.sleep(min(delay,60))
            if rec.kind not in peers:
                peers[rec.kind]=socket.create_connection((a.host,wire.PORTS[rec.kind]),timeout=3)
            peers[rec.kind].sendall(wire.encode(rec))
    finally:
        for s in peers.values():s.close()
if __name__=='__main__':main()

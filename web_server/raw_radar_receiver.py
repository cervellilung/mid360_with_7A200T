"""Bounded ACX750 raw-UDP capture into existing M3CP radar records."""
from __future__ import annotations
import argparse,json,socket,time
from pathlib import Path
from .raw_m3cp.wire import Record,RADAR,FLAG_BAD_SOURCE,encode,HEADER,decode,decode_header
from .pc_perception.protocol import decode_mid360,PacketError

def inspect_payload(raw,host_ns):
    try:
        p=decode_mid360(raw,host_ns)
        return p, None
    except PacketError as e:
        return None, str(e)

def check_recording(path):
    count=valid=bad=points=0
    with Path(path).open('rb') as f:
        while header:=f.read(HEADER.size):
            fields=decode_header(header,RADAR)
            raw=f.read(fields[6]);record=decode(header+raw,RADAR)
            packet,error=inspect_payload(record.payload,record.capture_us*1000)
            count+=1
            if error:bad+=1
            else:valid+=1;points+=len(packet.points)
    return dict(records=count,valid_mid360=valid,bad_mid360=bad,points=points)

def capture(bind,board,duration,output):
    output=Path(output);output.mkdir(parents=True,exist_ok=False)
    stats=dict(received=0,valid=0,bad=0,wrong_sender=0,points=0,crc_present=0,
               counter_discontinuities=0,errors=[],first_packet_s=None,source_board=board,
               port=46110,duration_s=duration,mode='board_raw_udp')
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4*1024*1024)
    sock.bind((bind,46110));sock.settimeout(.2)
    started=time.monotonic();refresh=started;boot=time.time_ns()&0xffffffffffffffff;last=None
    try:
        with (output/'stream_1.bin').open('wb',buffering=1024*1024) as f:
            while time.monotonic()-started<duration:
                now=time.monotonic()
                if now>=refresh:
                    # This harmless non-command datagram resolves ARP and refreshes host MAC.
                    sock.sendto(b'RAW_CAPTURE_HOST',(board,56300));refresh=now+5
                try:raw,peer=sock.recvfrom(65535)
                except socket.timeout:continue
                if peer!=(board,56301):stats['wrong_sender']+=1;continue
                host_ns=time.monotonic_ns();packet,error=inspect_payload(raw,host_ns)
                if stats['first_packet_s'] is None:stats['first_packet_s']=round(time.monotonic()-started,3)
                if packet:
                    stats['valid']+=1;stats['points']+=len(packet.points)
                    stats['crc_present']+=int(packet.crc_present)
                    if last is not None and packet.udp_count!=((last+1)&65535):stats['counter_discontinuities']+=1
                    last=packet.udp_count;device_us=packet.timestamp_ns//1000;flags=0
                else:
                    stats['bad']+=1;device_us=0;flags=FLAG_BAD_SOURCE
                    if len(stats['errors'])<8:stats['errors'].append(error)
                f.write(encode(Record(RADAR,flags,stats['received'],boot,host_ns//1000,device_us,raw)))
                stats['received']+=1
    finally:
        sock.close();stats['elapsed_s']=round(time.monotonic()-started,3)
        (output/'summary.json').write_text(json.dumps(stats,indent=2),encoding='utf-8')
    stats['replay']=check_recording(output/'stream_1.bin')
    (output/'summary.json').write_text(json.dumps(stats,indent=2),encoding='utf-8')
    print(json.dumps(stats));print('RECORDING',output)
    return 0 if stats['valid']>0 and stats['bad']==0 else 1

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bind',default='192.168.1.10');p.add_argument('--board',default='192.168.1.50')
    p.add_argument('--duration',type=float,default=30);p.add_argument('--output',type=Path)
    p.add_argument('--check',type=Path)
    a=p.parse_args()
    if a.check:print(json.dumps(check_recording(a.check)));return 0
    if not 1<=a.duration<=120:p.error('duration must be 1..120 seconds')
    out=a.output or Path(__file__).resolve().parents[1]/'sample/radar'/time.strftime('board_raw_%Y%m%d_%H%M%S')
    return capture(a.bind,a.board,a.duration,out)
if __name__=='__main__':raise SystemExit(main())

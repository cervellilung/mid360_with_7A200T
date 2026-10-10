import tempfile,unittest,socket,threading,time
from pathlib import Path
import numpy as np
from web_server.pc_perception.protocol import POINT_DTYPE,encode_mid360_for_test
from web_server.raw_m3cp.wire import Record,RADAR,encode,decode
from web_server.raw_radar_receiver import inspect_payload,check_recording
class RawRecordingTest(unittest.TestCase):
 def test_packet_record_replay(self):
  pts=np.zeros(96,dtype=POINT_DTYPE);pts['x']=np.arange(96)*10
  raw=encode_mid360_for_test(pts,123456000,65535)
  packet,error=inspect_payload(raw,9000);self.assertIsNone(error)
  wire=encode(Record(RADAR,0,0,42,9,123456,raw));self.assertEqual(decode(wire).payload,raw)
  with tempfile.TemporaryDirectory() as d:
   path=Path(d)/'stream_1.bin';path.write_bytes(wire)
   self.assertEqual(check_recording(path),dict(records=1,valid_mid360=1,bad_mid360=0,points=96))
   path.write_bytes(wire[:-1])
   with self.assertRaises(ValueError):check_recording(path)
  damaged=bytearray(raw);damaged[-1]^=1
  self.assertIn('CRC',inspect_payload(damaged,0)[1])
 def test_udp_capture_and_replay(self):
  from web_server.raw_radar_receiver import capture
  with tempfile.TemporaryDirectory() as d:
   out=Path(d)/'capture';result=[]
   guard=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);guard.bind(('127.0.0.1',56300))
   sender=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sender.bind(('127.0.0.1',56301))
   thread=threading.Thread(target=lambda:result.append(capture('127.0.0.1','127.0.0.1',1.2,out)))
   thread.start();time.sleep(.15)
   pts=np.zeros(96,dtype=POINT_DTYPE)
   for i in range(3):sender.sendto(encode_mid360_for_test(pts,1000000+i*1000,i),('127.0.0.1',46110));time.sleep(.02)
   thread.join(3);sender.close();guard.close()
   self.assertFalse(thread.is_alive());self.assertEqual(result,[0])
   self.assertEqual(check_recording(out/'stream_1.bin')['records'],3)
if __name__=='__main__':unittest.main()

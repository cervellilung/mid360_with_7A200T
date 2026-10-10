import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest
from web_server import m3tl
from web_server.full_board_test import Audit, receive, replay, check_continuity


def packet(kind, fields, seq=0):
    return m3tl.encode_frame(kind, m3tl.encode_payload(kind, fields), sequence=seq, timestamp_ms=100)


class FullBoardTest(unittest.TestCase):
    def test_sequence_wrap_gap_duplicate_reorder(self):
        a=Audit()
        for seq in (0xffffffff,0,0,3,2):
            a.add(packet(6, {}, seq), ('board',1), 'board')
        self.assertEqual(a.errors['duplicate_sequence'],1)
        self.assertEqual(a.errors['sequence_gap'],1)
        self.assertEqual(a.errors['reordered_or_reset'],1)

    def test_corruption_and_wrong_source(self):
        a=Audit(); data=bytearray(packet(6,{}));data[-1]^=1
        self.assertFalse(a.add(bytes(data),('board',1),'board'))
        self.assertFalse(a.add(packet(6,{}),('other',1),'board'))
        self.assertEqual(a.counts,{})

    def test_bounds_and_grid_contract(self):
        a=Audit()
        a.add(packet(3,{'targets':[{'x_min':10,'x_max':0}]}),('board',1),'board')
        a.add(packet(5,{'rows':1,'cols':1,'cell_mm':50}),('board',1),'board')
        self.assertEqual(a.errors['inverted_target_bounds'],1)
        self.assertEqual(a.errors['grid_contract'],1)

    def test_missing_channels_never_pass(self):
        a=Audit();a.add(packet(6,{}),('board',1),'board')
        self.assertEqual(a.report((1,3,5,6))['missing_types'],[1,3,5])

    def test_grid_last_cell_and_padding(self):
        a=Audit(); bitmap=bytearray(413); bitmap[-1]=8
        a.add(packet(5,{'cell_mm':100,'bitmap':bitmap}),('board',1),'board')
        self.assertEqual(a.errors,{})
        bitmap[-1]=16
        a.add(packet(5,{'cell_mm':100,'bitmap':bitmap},1),('board',1),'board')
        self.assertEqual(a.errors['grid_padding_bits'],1)

    def test_heartbeat_stall_after_initial_success(self):
        result={'status':'pass','errors':{}}
        check_continuity(result,[31.375,31.875,37.875],90)
        self.assertEqual(result['status'],'fail')
        self.assertEqual(result['errors']['heartbeat_stream_stalled'],1)
        self.assertEqual(result['continuity']['tail_s'],52.125)
        healthy={'status':'pass','errors':{}}
        check_continuity(healthy,[10,10.5,11],11.5)
        self.assertEqual(healthy['status'],'pass')

    def test_duration_bound(self):
        with self.assertRaises(ValueError): receive('127.0.0.1',0,'board',121,12,Path('unused'))
        with self.assertRaises(ValueError): receive('127.0.0.1',0,'board',1,12,Path('unused'))

    def test_loopback_record_and_replay(self):
        with tempfile.TemporaryDirectory() as tmp:
            with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as reserve:
                reserve.bind(('127.0.0.1',0));port=reserve.getsockname()[1]
            data=[packet(1,{'pll_locked':1,'ddr3_calib_done':1,'cam_init_done':1}),
                  packet(3,{'targets':[{'nearest_mm':1320,'x_min':900,'x_max':950}]}),
                  packet(5,{'cell_mm':100}),packet(6,{'frames':100})]
            def send():
                time.sleep(.15)
                with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
                    for wire in data: sock.sendto(wire,('127.0.0.1',port))
            t=threading.Thread(target=send);t.start()
            out=Path(tmp)/'capture'
            live=receive('127.0.0.1',port,'127.0.0.1',.5,0,out);t.join()
            replayed=replay(out/'telemetry_wire.jsonl','127.0.0.1')
            self.assertEqual(live['status'],'pass',live)
            for key in ('messages','latest','errors','missing_types'):
                self.assertEqual(live[key],replayed[key])
            self.assertEqual(live['ar_visual'],'pending_user_observation')


if __name__=='__main__': unittest.main()

"""Validate cache topology and deterministic replay without hardware."""
from pathlib import Path
import hashlib
import importlib.util
import json
import sys
import tempfile
import numpy as np
from .assets import pack, write_binary
from .mesh import make_mesh
from .source import collect_points
from web_server.ar_render.m3cp_recording import StreamFile

ROOT=Path(__file__).resolve().parents[2]

def main():
    evidence=ROOT/'results/mesh_quality_20261008'
    output=ROOT/'sample/car_showcase/surface_improved_20261008'
    manifest=json.loads((output/'manifest.json').read_text(encoding='utf-8'))
    topology=[]
    for entry in [dict(mesh=f[key], t=f['t']) for f in manifest['frames'] for key in ('mesh','planar_mesh')]:
        data=(output/entry['mesh']).read_bytes()
        magic,n,t,v=np.frombuffer(data,dtype='<u4',count=4)
        assert int(magic)==0x4D335348 and v==1
        assert len(data)==16+37*int(n)+12*int(t)
        xyz=np.frombuffer(data,dtype='<f4',count=int(n)*3,offset=16)
        idx=np.frombuffer(data,dtype='<u4',count=int(t)*3,offset=16+24*int(n))
        assert np.isfinite(xyz).all() and (not len(idx) or idx.max()<n)
        topology.append(dict(t=entry['t'],vertices=int(n),triangles=int(t)))
    with StreamFile(ROOT/'sample/sessions/linux_dual_final_01/stream_1.bin') as radar, StreamFile(ROOT/'sample/sessions/linux_dual_final_01/stream_2.bin') as camera:
        base=max(radar.times[0],camera.times[0])
        points,_,_=collect_points(radar,base+1_000_000,1_000_000)
        current=make_mesh(points)
        spec=importlib.util.spec_from_file_location('baseline_surface',evidence/'baseline_mesh.py')
        module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
        planar=make_mesh(points, planar_fill=True)
        np.testing.assert_array_equal(current.raw_vertices[current.observed], planar.raw_vertices[planar.observed])
        np.testing.assert_array_equal(current.vertices[current.observed], planar.vertices[planar.observed])
        old=module.make_mesh(points)
        assert old.observed_cells==current.observed_cells
        reference=current.raw_vertices[current.observed]
        prior=old.vertices[old.observed]
        shift=np.linalg.norm(prior-reference,axis=1)*1000
        actual=np.linalg.norm(current.vertices[current.observed]-reference,axis=1)*1000
        replay=[]
        with tempfile.TemporaryDirectory() as temp:
            for i in (0,50,100):
                entry=manifest['frames'][i]
                cloud,_,_=collect_points(radar,base+round(entry['t']*1e6),100_000)
                for mode,key in ((False,'mesh'),(True,'planar_mesh')):
                    mesh=make_mesh(cloud,planar_fill=mode);path=Path(temp)/'check.m3mesh';write_binary(path,mesh)
                    expected=(output/entry[key]).read_bytes()
                    assert path.read_bytes()==expected
                    replay.append(dict(frame=i,planar=mode,sha256=hashlib.sha256(expected).hexdigest()))
    report=dict(real_source='linux_dual_final_01',static_seconds=2,frame_window_ms=200,
                before=pack(old)['stats'],after=pack(current)['stats'],planar=pack(planar)['stats'],
                true_displacement_mm=dict(before_p95=float(np.percentile(shift,95)),
                                          after_p95=float(np.percentile(actual,95)),
                                          after_max=float(actual.max())),
                cache_frames=len(topology),deterministic_samples=replay,
                replay_build_ms=dict(median=float(np.median([f['stats']['build_ms'] for f in manifest['frames']])),
                                     p95=float(np.percentile([f['stats']['build_ms'] for f in manifest['frames']],95))),
                preserved_observed_cells=True,passed=True,
                limits=['Not all holes are fillable', 'Net rejection is geometric, not material recognition',
                        'No hardware or Pi performance validation',
                        'Viewer full-scene switch disables default forward crop; mesh radius is 12m'])
    (evidence/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False))

if __name__=='__main__':main()

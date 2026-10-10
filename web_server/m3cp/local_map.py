"""Odom-only fusion with explicit extrinsic validity. Missing pose disables fusion."""
from collections import deque, OrderedDict
import math
import numpy as np
try:
    from web_server.pc_perception.odom import decode_odom_frame
except ModuleNotFoundError:  # legacy standalone launch from web_server/
    from pc_perception.odom import decode_odom_frame

def rotation(roll, pitch, yaw):
    cr,sr,cp,sp,cy,sy = math.cos(roll),math.sin(roll),math.cos(pitch),math.sin(pitch),math.cos(yaw),math.sin(yaw)
    return np.array([[cy*cp,cy*sp*sr-sy*cr,cy*sp*cr+sy*sr],
                     [sy*cp,sy*sp*sr+cy*cr,sy*sp*cr-cy*sr],[-sp,cp*sr,cp*cr]])

class LocalMap:
    def __init__(self, config):
        self.valid_extrinsic = bool(config.get('extrinsic_valid', False))
        self.R = np.asarray(config.get('rotation', np.eye(3)),dtype=float).reshape(3,3)
        self.t = np.asarray(config.get('translation_mm',[0,0,0]),dtype=float)
        if not np.isfinite(self.R).all() or not np.isfinite(self.t).all() or not np.allclose(self.R.T@self.R,np.eye(3),atol=1e-4) or np.linalg.det(self.R)<.99:
            raise ValueError('invalid lidar-to-body rigid transform')
        self.voxel = max(20,int(config.get('voxel_mm',50)))
        self.limit = min(200000,max(100,int(config.get('max_points',200000))))
        self.radius = min(12000,int(config.get('radius_mm',12000)))
        self.max_dt = int(config.get('pose_tolerance_us',50000))
        self.poses = deque(maxlen=256)
        self.cells = OrderedDict()
        self.trajectory = deque(maxlen=1000)
        self.status = 'no_pose'
        self.rejects = 0
        self.boot = None
        self.last_prune=0

    def reset(self):
        self.poses.clear(); self.cells.clear(); self.trajectory.clear()
        self.status = 'no_pose'

    def odom(self, record):
        od = decode_odom_frame(record.payload,record.capture_us*1000)
        p = np.array(od.position_raw,dtype=float)
        a = np.array(od.attitude_raw,dtype=float)/10000
        if record.boot_id != self.boot:
            self.reset(); self.boot = record.boot_id
        if self.poses:
            dt = (record.capture_us-self.poses[-1][0])/1e6
            oldp,olda = self.poses[-1][1:]
            angle = abs((a[2]-olda[2]+math.pi)%(2*math.pi)-math.pi)
            if dt<=0 or dt>1 or np.linalg.norm(p-oldp)>200+10000*dt or angle>.2+6*dt:
                self.rejects += 1; self.status='pose_discontinuity'; self.poses.clear()
                # A jump starts a new map; never join incompatible coordinate epochs.
                self.cells.clear(); self.trajectory.clear()
                return False
        self.poses.append((record.capture_us,p,a))
        self.trajectory.append((p/1000).tolist())
        return True

    def pose(self, stamp):
        if not self.poses:
            return None
        nearest = min(self.poses,key=lambda p:abs(p[0]-stamp))
        if abs(nearest[0]-stamp)>self.max_dt:
            return None
        # Nearest sample is deliberate; do not extrapolate an unavailable future pose.
        return nearest

    def fuse(self, points, stamp):
        pose = self.pose(stamp)
        if not self.valid_extrinsic:
            self.status='extrinsic_unverified'; return False
        if pose is None:
            self.status='pose_missing_or_stale'; return False
        _,p,a = pose
        points = np.asarray(points).reshape(-1,3)
        r = np.linalg.norm(points,axis=1)
        points = points[np.isfinite(points).all(axis=1)&(r>=300)&(r<=self.radius)]
        world = (points@self.R.T+self.t)@rotation(*a).T+p
        for v in world:
            key=tuple(np.floor(v/self.voxel).astype(int))
            self.cells[key]=v
            self.cells.move_to_end(key)
        # Bound storage and spatial extent around the latest body position.
        while len(self.cells)>self.limit:
            self.cells.popitem(last=False)
        if stamp-self.last_prune>=1000000:
            radius_sq=self.radius**2
            for key in list(self.cells):
                delta=self.cells[key]-p
                if delta@delta>radius_sq:del self.cells[key]
            self.last_prune=stamp
        self.status='odom_fusion_no_loop_closure'
        return True

    def body_points(self, stamp):
        pose=self.pose(stamp)
        if pose is None or not self.cells:
            return np.zeros((0,3),dtype=np.float32)
        _,p,a=pose
        return (np.array(list(self.cells.values()))-p)@rotation(*a)

"""Import only ch54 camera initialization dependencies; leave reference untouched."""
from pathlib import Path
import hashlib
import json

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[1]
SOURCE = ROOT/'routine/references/acx750_dual/ch54_acx750_ov5640x2_udp_rgmii/ov5640x2_udp_rgmii.srcs/sources_1/camera_init'
DEST = HERE/'acx750_stereo_basic.srcs/sources_1/imports/vendor_camera'
names = ['camera_init.v', 'ov5640_init_table_rgb.v', 'ov5640_init_table_jpeg.v',
         'ov7725_init_table_rgb.v', 'i2c_control/i2c_control.v', 'i2c_control/i2c_bit_shift.v']
DEST.mkdir(parents=True, exist_ok=True)
records=[]
for name in names:
    raw=(SOURCE/name).read_bytes()
    try:
        decoded=raw.decode('utf-8-sig');encoding='utf-8'
    except UnicodeDecodeError:
        decoded=raw.decode('gb18030');encoding='gb18030'
    target=DEST/Path(name).name
    if target.exists():
        raise SystemExit('Existing imports are authoritative; refusing to overwrite: '+str(target))
    target.write_text(decoded, encoding='utf-8', newline='\n')
    records.append({'source':str((SOURCE/name).relative_to(ROOT)), 'file':target.name,
                    'source_sha256':hashlib.sha256(raw).hexdigest(), 'source_encoding':encoding})
(DEST/'provenance.json').write_text(json.dumps(records, ensure_ascii=False, indent=2),encoding='utf-8')
print('IMPORTED_VENDOR_CAMERA_FILES:',len(records))

"""Build an A/B sheet so a human can say which way up a camera is mounted.

Left half is the frame exactly as recorded, right half is the same frame rotated
180 degrees. Whichever half looks right-side up tells us the roll to feed the
radar-to-camera extrinsic in render_ar_anaglyph.py.

Usage: python make_orientation_sheet.py <input.png> <output.png>
"""

from __future__ import annotations

import sys
from pathlib import Path

import cv2
import numpy as np


def label(image: np.ndarray, text: str) -> np.ndarray:
    canvas = image.copy()
    cv2.rectangle(canvas, (0, 0), (canvas.shape[1], 30), (0, 0, 0), -1)
    cv2.putText(canvas, text, (10, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                (255, 255, 255), 2, cv2.LINE_AA)
    return canvas


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    source = Path(sys.argv[1])
    target = Path(sys.argv[2])
    frame = cv2.imread(str(source))
    if frame is None:
        print(f"cannot read {source}")
        return 1
    left = label(frame, "A  as recorded")
    right = label(cv2.rotate(frame, cv2.ROTATE_180), "B  rotated 180")
    sheet = np.hstack([left, np.full((frame.shape[0], 4, 3), 255, np.uint8), right])
    target.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(target), sheet)
    print(f"{sheet.shape[1]}x{sheet.shape[0]} -> {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
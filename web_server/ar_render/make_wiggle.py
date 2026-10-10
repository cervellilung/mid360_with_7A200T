"""Build a wiggle-stereo clip from the saved left/right eye images.

Anaglyph needs red/cyan glasses. Wiggle stereo does not: alternating the two
eye views a few times a second lets the brain read depth from the motion
parallax alone, which makes it possible to verify the stereo geometry even with
no glasses at hand.

Also writes a side-by-side pair, for viewers who can free-view.

Usage: python make_wiggle.py <render output dir> [--fps 24] [--hold 3]
"""

from __future__ import annotations

import argparse
from pathlib import Path

import cv2
import numpy as np


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", help="render output directory containing eye_left/eye_right")
    parser.add_argument("--fps", type=int, default=24)
    parser.add_argument("--hold", type=int, default=3,
                        help="video frames per eye view; alternation rate is fps/hold")
    args = parser.parse_args()

    root = Path(args.directory)
    left_files = sorted((root / "eye_left").glob("*.png"))
    right_files = sorted((root / "eye_right").glob("*.png"))
    if not left_files or len(left_files) != len(right_files):
        print(f"need matching eye_left/eye_right images under {root}")
        return 1

    sample = cv2.imread(str(left_files[0]))
    height, width = sample.shape[:2]
    writer = cv2.VideoWriter(str(root / "wiggle_stereo.mp4"),
                             cv2.VideoWriter_fourcc(*"mp4v"), args.fps, (width, height))
    if not writer.isOpened():
        print("cannot open the mp4 writer (no suitable codec in this OpenCV build)")
        return 1

    for left_path, right_path in zip(left_files, right_files):
        left = cv2.imread(str(left_path))
        right = cv2.imread(str(right_path))
        if left is None or right is None:
            continue
        for _ in range(args.hold):
            writer.write(left)
        for _ in range(args.hold):
            writer.write(right)
    writer.release()

    left = cv2.imread(str(left_files[0]))
    right = cv2.imread(str(right_files[0]))
    gap = np.zeros((height, 8, 3), np.uint8)
    cv2.imwrite(str(root / "stereo_pair_sample.png"), np.hstack([left, gap, right]))

    seconds = len(left_files) * 2 * args.hold / float(args.fps)
    print(f"{len(left_files)} pairs -> {root / 'wiggle_stereo.mp4'} "
          f"({seconds:.1f}s, alternates at {args.fps / args.hold:.1f} Hz)")
    print(f"side-by-side pair -> {root / 'stereo_pair_sample.png'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
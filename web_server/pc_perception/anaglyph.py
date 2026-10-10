"""Fixed-point anaglyph disparity derived from LiDAR range.

A single camera cannot supply a stereo pair, but every projected radar point
carries a measured range. Mapping that range through a virtual baseline turns
the AR layer into a real stereoscopic layer: the camera image stays a flat
neutral background, while the AR elements sit at their true depth and separate
into red/cyan when viewed through anaglyph glasses.

Everything here is integer arithmetic so the identical formula can be ported to
the PL, matching the fixed-point style of projection.py.
"""

from __future__ import annotations

from dataclasses import dataclass

Q8 = 1 << 8
Q16 = 1 << 16

# Sensible defaults for a 640x480 USB camera next to a MID-360. They are
# assumptions, not measurements: there is no calibration file for this mount
# yet, so every default is overridable from the command line.
DEFAULT_BASELINE_MM = 60        # virtual viewer baseline (inter-pupillary)
DEFAULT_FX_PX = 520             # focal length in pixels
DEFAULT_ZERO_PARALLAX_MM = 3000  # range that lands exactly on the screen plane
DEFAULT_MAX_PX = 40             # clamp so extreme near ranges stay viewable


@dataclass(frozen=True)
class DisparityModel:
    """Maps a measured range (mm) onto a red/cyan pixel separation."""

    baseline_mm: int = DEFAULT_BASELINE_MM
    fx_q16: int = DEFAULT_FX_PX * Q16
    zero_parallax_mm: int = DEFAULT_ZERO_PARALLAX_MM
    max_q8: int = DEFAULT_MAX_PX * Q8

    def disparity_q8(self, distance_mm: int) -> int:
        """Signed separation in Q8 pixels. Positive means "nearer than the plane"."""
        distance = int(distance_mm)
        if distance <= 1:
            return self.max_q8
        numerator = self.baseline_mm * self.fx_q16 * (self.zero_parallax_mm - distance) * Q8
        denominator = distance * self.zero_parallax_mm * Q16
        value = numerator // denominator
        return max(-self.max_q8, min(self.max_q8, value))

    def eye_offsets_q8(self, distance_mm: int) -> tuple[int, int]:
        """(left eye, right eye) horizontal offsets.

        The left (red) copy moves right and the right (cyan) copy moves left for
        near objects, which is what makes them float in front of the screen.
        """
        half = self.disparity_q8(distance_mm) // 2
        return half, -half

    def disparity_px(self, distance_mm: int) -> float:
        return self.disparity_q8(distance_mm) / float(Q8)
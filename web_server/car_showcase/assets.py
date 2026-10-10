"""Shared preview serialization; preserves M3MESH version 1."""
import json
from pathlib import Path
import numpy as np
from .mesh import Mesh

def pack(mesh: Mesh) -> dict:
    return {
        "vertices": np.round(mesh.vertices, 3).reshape(-1).tolist(),
        "raw_vertices": np.round(mesh.raw_vertices, 3).reshape(-1).tolist(),
        "normals": np.round(mesh.normals, 3).reshape(-1).tolist(),
        "triangles": mesh.triangles.reshape(-1).tolist(),
        "observed": mesh.observed.astype(np.uint8).tolist(),
        "stats": {"input_points": mesh.input_points,
                  "observed_cells": mesh.observed_cells,
                  "filled_cells": mesh.filled_cells,
                  "triangles": len(mesh.triangles),
                  "edge_rejections": mesh.edge_rejections,
                  "build_ms": round(mesh.build_ms, 1),
                  "p95_shift_mm": round(mesh.p95_shift_mm, 1)},
    }


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


def write_binary(path: Path, mesh: Mesh) -> None:
    """Four little-endian counts, then positions, normals, indices and support flags."""
    with path.open("wb") as handle:
        np.asarray((0x4D335348, len(mesh.vertices), len(mesh.triangles), 1), dtype="<u4").tofile(handle)
        np.asarray(mesh.vertices, dtype="<f4").tofile(handle)
        np.asarray(mesh.normals, dtype="<f4").tofile(handle)
        np.asarray(mesh.triangles, dtype="<u4").tofile(handle)
        mesh.observed.astype("u1").tofile(handle)
        np.asarray(mesh.raw_vertices, dtype="<f4").tofile(handle)



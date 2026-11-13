#!/usr/bin/env python3
"""build.py on a PC without Blender: the procedural models built in plain Python.

    python tools/models/noblender.py [names...] [--out=DIR] [--compare]

Runs the same model functions (kit.py, detail.py, space_kit.py and the families) against small
stand-ins for Blender's `mathutils`, `bmesh` and `bpy`, and writes the same glTF layout kit.export
does: a node per part, a primitive per material, planar UVs, the bake (bake.py) as COLOR_0 alpha
and TEXCOORD_1-3. Blender stays the reference: bevels are plane cuts here (a convex primitive only;
others are left sharp), corners shade by the same crease rule, and a rebuild with real Blender
gives the same shapes to within a chamfer. `mathutils.noise` is a stand-in, so a model that uses it
comes out with different lumps: name those to Blender. `--compare` builds to a temporary folder
and reports triangles and bounds against the committed .glb without changing it.

Run part_colors.py after it, as after build.py.
"""

import importlib
import json
import math
import os
import struct
import sys
import tempfile
import time
import traceback
import types

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
GENERATOR = "Zenith tools/models/noblender.py"


# ---------------------------------------------------------------------------------------------
# mathutils.

class Vector:
    __slots__ = ("v",)

    def __init__(self, seq=(0.0, 0.0, 0.0)):
        self.v = [float(c) for c in seq]

    x = property(lambda s: s.v[0], lambda s, c: s.v.__setitem__(0, float(c)))
    y = property(lambda s: s.v[1], lambda s, c: s.v.__setitem__(1, float(c)))
    z = property(lambda s: s.v[2], lambda s, c: s.v.__setitem__(2, float(c)))

    def __iter__(self):
        return iter(self.v)

    def __len__(self):
        return len(self.v)

    def __getitem__(self, i):
        return self.v[i]

    def __setitem__(self, i, c):
        self.v[i] = float(c)

    def __repr__(self):
        return "Vector(%s)" % self.v

    def __add__(self, o):
        return Vector(a + b for a, b in zip(self.v, o))

    __radd__ = __add__

    def __sub__(self, o):
        return Vector(a - b for a, b in zip(self.v, o))

    def __rsub__(self, o):
        return Vector(b - a for a, b in zip(self.v, o))

    def __mul__(self, k):
        if isinstance(k, Vector):
            return Vector(a * b for a, b in zip(self.v, k.v))
        return Vector(a * k for a in self.v)

    __rmul__ = __mul__

    def __truediv__(self, k):
        return Vector(a / k for a in self.v)

    def __neg__(self):
        return Vector(-a for a in self.v)

    def copy(self):
        return Vector(self.v)

    def dot(self, o):
        return sum(a * b for a, b in zip(self.v, o))

    def cross(self, o):
        a, b = self.v, list(o)
        return Vector((a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]))

    @property
    def length(self):
        return math.sqrt(sum(a * a for a in self.v))

    @property
    def length_squared(self):
        return sum(a * a for a in self.v)

    def normalized(self):
        n = self.length
        return Vector(self.v) if n == 0 else self / n

    def normalize(self):
        self.v = self.normalized().v

    def lerp(self, o, t):
        return Vector(a + (b - a) * t for a, b in zip(self.v, o))

    def orthogonal(self):
        x, y, z = (abs(c) for c in self.v)
        axis = (1, 0, 0) if x <= y and x <= z else (0, 1, 0) if y <= z else (0, 0, 1)
        return self.cross(axis)

    def angle(self, o, fallback=None):
        a, b = self.length, Vector(o).length
        if a == 0 or b == 0:
            return fallback
        return math.acos(max(-1.0, min(1.0, self.dot(o) / (a * b))))

    def rotation_difference(self, o):
        a, b = self.normalized(), Vector(o).normalized()
        axis = a.cross(b)
        if axis.length < 1e-9:
            axis = a.orthogonal() if a.dot(b) < 0 else Vector((0, 0, 1))
        return _Rotation(axis, a.angle(b, 0.0))


class _Rotation:
    def __init__(self, axis, angle):
        self.axis, self.angle = axis, angle

    def to_matrix(self):
        return Matrix.Rotation(self.angle, 3, self.axis)


class Matrix:
    def __init__(self, rows=None):
        self.m = np.identity(4) if rows is None else np.array([list(r) for r in rows], dtype=np.float64)

    def __getitem__(self, i):
        return self.m[i]

    @staticmethod
    def Identity(n):
        return Matrix(np.identity(n))

    @staticmethod
    def Translation(t):
        m = np.identity(4)
        m[:3, 3] = list(t)[:3]
        return Matrix(m)

    @staticmethod
    def Rotation(angle, size, axis):
        if isinstance(axis, str):
            axis = {"X": (1, 0, 0), "Y": (0, 1, 0), "Z": (0, 0, 1)}[axis]
        x, y, z = Vector(axis).normalized()
        c, s, t = math.cos(angle), math.sin(angle), 1 - math.cos(angle)
        r = np.array([[t * x * x + c, t * x * y - s * z, t * x * z + s * y],
                      [t * x * y + s * z, t * y * y + c, t * y * z - s * x],
                      [t * x * z - s * y, t * y * z + s * x, t * z * z + c]])
        m = np.identity(size)
        m[:3, :3] = r
        return Matrix(m)

    def __matmul__(self, o):
        if isinstance(o, Matrix):
            return Matrix(self.m @ o.m)
        v = list(o)
        if self.m.shape[0] == 4:
            return Vector((self.m @ np.array(v[:3] + [1.0]))[:3])
        return Vector(self.m @ np.array(v[:3]))

    def to_3x3(self):
        return Matrix(self.m[:3, :3])

    def to_4x4(self):
        m = np.identity(4)
        m[:3, :3] = self.m[:3, :3]
        if self.m.shape[0] == 4:
            m[:3, 3] = self.m[:3, 3]
        return Matrix(m)

    def determinant(self):
        return float(np.linalg.det(self.m))

    @property
    def translation(self):
        return Vector(self.m[:3, 3])


def _noise(q):
    """A smooth stand-in for mathutils.noise.noise (not Blender's values)."""
    x, y, z = q
    return (math.sin(x * 1.7 + y * 0.9) + math.sin(y * 2.3 + z * 1.3) + math.sin(z * 1.9 + x * 2.1)) / 3.0


# ---------------------------------------------------------------------------------------------
# bmesh: only what the model code uses.

class BMVert:
    __slots__ = ("co", "faces")

    def __init__(self, co):
        self.co = Vector(co)
        self.faces = []

    @property
    def link_faces(self):
        return self.faces


class BMFace:
    __slots__ = ("verts", "material_index")

    def __init__(self, verts):
        self.verts = list(verts)
        self.material_index = 0

    @property
    def normal(self):
        n = [0.0, 0.0, 0.0]
        for a, b in zip(self.verts, self.verts[1:] + self.verts[:1]):
            p, q = a.co.v, b.co.v
            n[0] += (p[1] - q[1]) * (p[2] + q[2])
            n[1] += (p[2] - q[2]) * (p[0] + q[0])
            n[2] += (p[0] - q[0]) * (p[1] + q[1])
        return Vector(n).normalized()

    def calc_center_median(self):
        return sum((v.co for v in self.verts), Vector()) / len(self.verts)


class BMEdge:
    __slots__ = ("verts", "link_faces")

    def __init__(self, a, b):
        self.verts = [a, b]
        self.link_faces = []

    @property
    def is_boundary(self):
        return len(self.link_faces) == 1


class _Verts(list):
    def new(self, co=(0.0, 0.0, 0.0)):
        v = BMVert(co)
        self.append(v)
        return v

    def ensure_lookup_table(self):
        pass


class _Faces(list):
    def __init__(self, seen):
        super().__init__()
        self.seen = seen

    def new(self, verts):
        verts = list(verts)
        key = frozenset(id(v) for v in verts)
        if len(key) != len(verts) or key in self.seen:
            raise ValueError("duplicate face")
        self.seen.add(key)
        f = BMFace(verts)
        self.append(f)
        return f

    def ensure_lookup_table(self):
        pass

    def __getitem__(self, i):
        got = list.__getitem__(self, i)
        return list(got) if isinstance(i, slice) else got


class BMesh:
    def __init__(self):
        self.verts = _Verts()
        self.faces = _Faces(set())

    @property
    def edges(self):
        found = {}
        for f in self.faces:
            for a, b in zip(f.verts, f.verts[1:] + f.verts[:1]):
                key = (id(a), id(b)) if id(a) < id(b) else (id(b), id(a))
                if key not in found:
                    found[key] = BMEdge(a, b)
                found[key].link_faces.append(f)
        return list(found.values())

    def normal_update(self):
        pass

    def free(self):
        pass


def _replace(bm, polygons):
    """Rebuilds bm from polygons of points, welding equal points."""
    bm.verts.clear()
    bm.faces.clear()
    bm.faces.seen.clear()
    by_key = {}
    for points in polygons:
        verts = []
        for p in points:
            key = tuple(round(c, 6) for c in p)
            if key not in by_key:
                by_key[key] = bm.verts.new(p)
            if not verts or verts[-1] is not by_key[key]:
                verts.append(by_key[key])
        if len(verts) > 1 and verts[0] is verts[-1]:
            verts.pop()
        if len(verts) >= 3:
            try:
                bm.faces.new(verts)
            except ValueError:
                pass


def _clip(polygons, point, normal):
    """Cuts convex polygons by the half-space normal . (x - point) <= 0, closing the cut."""
    out, cut = [], []
    for poly in polygons:
        dist = [float(np.dot(p - point, normal)) for p in poly]
        kept = []
        for i, p in enumerate(poly):
            j = (i + 1) % len(poly)
            if dist[i] <= 1e-9:
                kept.append(p)
            if (dist[i] > 1e-9) != (dist[j] > 1e-9):
                q = p + (poly[j] - p) * (dist[i] / (dist[i] - dist[j]))
                kept.append(q)
                cut.append(q)
        if len(kept) >= 3:
            out.append(kept)
    if len(cut) >= 3:
        centre = np.mean(cut, axis=0)
        u = cut[0] - centre
        u = u / max(np.linalg.norm(u), 1e-12)
        w = np.cross(normal, u)
        order = sorted(range(len(cut)), key=lambda k: math.atan2(np.dot(cut[k] - centre, w), np.dot(cut[k] - centre, u)))
        ring = []
        for k in order:
            if not ring or np.linalg.norm(ring[-1] - cut[k]) > 1e-7:
                ring.append(cut[k])
        if len(ring) >= 3:
            out.append(ring)
    return out


def _bevel(bm, geom=(), offset=0.0, **_):
    """A one-segment chamfer of the given edges, as plane cuts. Only convex solids; others stay."""
    faces = list(bm.faces)
    if not geom or not faces:
        return
    centre = np.mean([np.array(v.co.v) for v in bm.verts], axis=0)
    for f in faces:
        n, p0 = np.array(f.normal.v), np.array(f.verts[0].co.v)
        if np.dot(centre - p0, n) > 0:
            return
        if any(np.dot(np.array(v.co.v) - p0, n) > 1e-5 for v in bm.verts):
            return
    planes = []
    for e in geom:
        a, b = np.array(e.verts[0].co.v), np.array(e.verts[1].co.v)
        d = (b - a) / max(np.linalg.norm(b - a), 1e-12)
        f1, f2 = e.link_faces
        n1, n2 = np.array(f1.normal.v), np.array(f2.normal.v)
        in1, in2 = np.cross(n1, d), np.cross(n2, d)
        in1 = in1 if np.dot(in1, centre - a) > 0 else -in1
        in2 = in2 if np.dot(in2, centre - a) > 0 else -in2
        p1, p2 = a + in1 * offset, a + in2 * offset
        n = np.cross(d, p2 - p1)
        n = n / max(np.linalg.norm(n), 1e-12)
        if np.dot(n, n1 + n2) < 0:
            n = -n
        planes.append((p1, n))
    polys = [[np.array(v.co.v) for v in f.verts] for f in faces]
    for point, normal in planes:
        polys = _clip(polys, point, normal)
    _replace(bm, [[tuple(p) for p in poly] for poly in polys])


def _create_cube(bm, size=1.0):
    h = size / 2
    v = [bm.verts.new((x, y, z)) for x in (-h, h) for y in (-h, h) for z in (-h, h)]
    for quad in ((0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)):
        bm.faces.new([v[i] for i in quad])


def _create_cone(bm, cap_ends=True, cap_tris=False, segments=12, radius1=1.0, radius2=1.0, depth=1.0):
    def circle(r, z):
        return [bm.verts.new((r * math.sin(2 * math.pi * i / segments), r * math.cos(2 * math.pi * i / segments), z))
                for i in range(segments)]
    lo, hi = circle(radius1, -depth / 2), circle(radius2, depth / 2)
    for i in range(segments):
        j = (i + 1) % segments
        bm.faces.new([lo[i], hi[i], hi[j], lo[j]])
    if cap_ends:
        bm.faces.new(lo)
        bm.faces.new(list(reversed(hi)))


def _create_uvsphere(bm, u_segments=12, v_segments=6, radius=1.0):
    top = bm.verts.new((0, 0, radius))
    bottom = bm.verts.new((0, 0, -radius))
    rows = []
    for r in range(1, v_segments):
        t = math.pi * r / v_segments
        rows.append([bm.verts.new((radius * math.sin(t) * math.cos(2 * math.pi * i / u_segments),
                                   radius * math.sin(t) * math.sin(2 * math.pi * i / u_segments), radius * math.cos(t)))
                     for i in range(u_segments)])
    for i in range(u_segments):
        j = (i + 1) % u_segments
        bm.faces.new([top, rows[0][i], rows[0][j]])
        bm.faces.new([bottom, rows[-1][j], rows[-1][i]])
        for a, b in zip(rows, rows[1:]):
            bm.faces.new([a[i], b[i], b[j], a[j]])


def _recalc_face_normals(bm, faces=None):
    """Winding made consistent across shared edges, then outward by signed volume, per piece."""
    faces = list(bm.faces if faces is None else faces)
    by_edge = {}
    for f in faces:
        for a, b in zip(f.verts, f.verts[1:] + f.verts[:1]):
            by_edge.setdefault(frozenset((id(a), id(b))), []).append(f)
    seen = set()
    for start in faces:
        if id(start) in seen:
            continue
        seen.add(id(start))
        piece, stack = [start], [start]
        while stack:
            f = stack.pop()
            for a, b in zip(f.verts, f.verts[1:] + f.verts[:1]):
                for g in by_edge[frozenset((id(a), id(b)))]:
                    if id(g) in seen:
                        continue
                    same = any(c is a and d is b for c, d in zip(g.verts, g.verts[1:] + g.verts[:1]))
                    if same:
                        g.verts.reverse()
                    seen.add(id(g))
                    piece.append(g)
                    stack.append(g)
        volume = 0.0
        for f in piece:
            o = f.verts[0].co
            for b, c in zip(f.verts[1:], f.verts[2:]):
                volume += o.dot(b.co.cross(c.co))
        if volume < 0:
            for f in piece:
                f.verts.reverse()


def _delete(bm, geom=(), context="VERTS"):
    gone = {id(v) for v in geom}
    kept = [f for f in bm.faces if not any(id(v) in gone for v in f.verts)]
    bm.faces.clear()
    bm.faces.extend(kept)
    bm.faces.seen.clear()
    bm.faces.seen.update(frozenset(id(v) for v in f.verts) for f in kept)
    survivors = [v for v in bm.verts if id(v) not in gone]
    bm.verts.clear()
    bm.verts.extend(survivors)


def _holes_fill(bm, edges=(), sides=0):
    """Closes boundary loops (a hemisphere's rim) with one face each."""
    nxt = {}
    for e in edges:
        f = e.link_faces[0]
        for a, b in zip(f.verts, f.verts[1:] + f.verts[:1]):
            if {id(a), id(b)} == {id(e.verts[0]), id(e.verts[1])}:
                nxt[id(b)] = a  # the new face runs the other way
    verts = {id(v): v for e in edges for v in e.verts}
    done = set()
    for k in list(nxt):
        if k in done:
            continue
        loop, cur = [], verts[k]
        while id(cur) not in done:
            done.add(id(cur))
            loop.append(cur)
            cur = nxt[id(cur)]
        if len(loop) >= 3:
            bm.faces.new(loop)


def _transform(bm, matrix=None, verts=()):
    for v in verts:
        v.co = matrix @ v.co


def _scale(bm, vec=(1, 1, 1), verts=()):
    for v in verts:
        v.co = v.co * Vector(vec)


def _translate(bm, vec=(0, 0, 0), verts=()):
    for v in verts:
        v.co = v.co + Vector(vec)


def _reverse_faces(bm, faces=()):
    for f in faces:
        f.verts.reverse()


def install():
    """Puts the stand-ins in sys.modules, so `import bmesh, bpy, mathutils` finds them."""
    if "mathutils" in sys.modules:
        return
    mathutils = types.ModuleType("mathutils")
    mathutils.Vector, mathutils.Matrix = Vector, Matrix
    mathutils.noise = types.SimpleNamespace(noise=_noise)
    bm = types.ModuleType("bmesh")
    bm.new = BMesh
    bm.ops = types.SimpleNamespace(
        create_cube=_create_cube, create_cone=_create_cone, create_uvsphere=_create_uvsphere, bevel=_bevel,
        recalc_face_normals=_recalc_face_normals, delete=_delete, holes_fill=_holes_fill, transform=_transform,
        scale=_scale, translate=_translate, reverse_faces=_reverse_faces)
    sys.modules.update({"mathutils": mathutils, "bmesh": bm, "bpy": types.ModuleType("bpy")})


# ---------------------------------------------------------------------------------------------
# Export: what kit.part_to_object, bake_blender_objects and Blender's glTF exporter do together.

def _triangles(points, normal):
    """A polygon's triangles as index triples: a fan when convex, else ears."""
    n = len(points)
    if n == 3:
        return [(0, 1, 2)]
    a = int(np.argmax(np.abs(normal)))
    keep = [k for k in range(3) if k != a]
    p2 = np.array(points)[:, keep]
    sign = 1.0 if normal[a] * (1 if a != 1 else -1) > 0 else -1.0

    def cross(i, j, k):
        return sign * ((p2[j, 0] - p2[i, 0]) * (p2[k, 1] - p2[i, 1]) - (p2[j, 1] - p2[i, 1]) * (p2[k, 0] - p2[i, 0]))

    if all(cross(i, (i + 1) % n, (i + 2) % n) >= -1e-12 for i in range(n)):
        return [(0, i, i + 1) for i in range(1, n - 1)]
    ring, out = list(range(n)), []
    while len(ring) > 3:
        for t in range(len(ring)):
            i, j, k = ring[t - 1], ring[t], ring[(t + 1) % len(ring)]
            if cross(i, j, k) <= 1e-12:
                continue
            inside = False
            for m in ring:
                if m not in (i, j, k) and cross(i, j, m) >= 0 and cross(j, k, m) >= 0 and cross(k, i, m) >= 0:
                    inside = True
                    break
            if not inside:
                out.append((i, j, k))
                ring.pop(t)
                break
        else:
            out.append((ring[0], ring[1], ring[2]))
            ring.pop(1)
    out.append(tuple(ring))
    return out


def _corner_normals(faces, sharp_degrees):
    """{(face, vertex): normal}: a vertex's faces joined across edges bending less than the crease."""
    cos_sharp = math.cos(math.radians(sharp_degrees))
    normals = [np.array(f.normal.v) for f in faces]
    at_vertex, by_edge = {}, {}
    for fi, f in enumerate(faces):
        for a, b in zip(f.verts, f.verts[1:] + f.verts[:1]):
            at_vertex.setdefault(id(a), []).append(fi)
            by_edge.setdefault(frozenset((id(a), id(b))), []).append(fi)
    out = {}
    for vid, fis in at_vertex.items():
        parent = {fi: fi for fi in fis}

        def find(i):
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i

        for fi in fis:
            for a, b in zip(faces[fi].verts, faces[fi].verts[1:] + faces[fi].verts[:1]):
                if vid not in (id(a), id(b)):
                    continue
                for fj in by_edge[frozenset((id(a), id(b)))]:
                    if fj in parent and fj != fi and float(np.dot(normals[fi], normals[fj])) >= cos_sharp:
                        parent[find(fi)] = find(fj)
        groups = {}
        for fi in fis:
            groups.setdefault(find(fi), []).append(fi)
        for members in groups.values():
            n = sum(normals[fi] for fi in members)
            n = n / max(np.linalg.norm(n), 1e-12)
            for fi in members:
                out[(fi, vid)] = n
    return out


def _flatten(part, bake):
    """A part's corners, world space: positions, normals, UVs, material and width per triangle."""
    tris, nrms, uvs, mats, widths = [], [], [], [], []
    faces = list(part.bm.faces)
    corners = _corner_normals(faces, part.sharp_angle)
    for fi, f in enumerate(faces):
        n = np.array(f.normal.v)
        ax = int(np.argmax(np.abs(n)))
        points = [v.co.v for v in f.verts]
        width = bake.polygon_width([v.co for v in f.verts])
        for i, j, k in _triangles(points, n):
            tri = [f.verts[i], f.verts[j], f.verts[k]]
            tris.append([v.co.v for v in tri])
            nrms.append([corners[(fi, id(v))] for v in tri])
            if part.uv_fn is not None:
                uvs.append([tuple(part.uv_fn(v.co)) for v in tri])
            elif ax == 2:
                uvs.append([(v.co.x, v.co.y) for v in tri])
            elif ax == 1:
                uvs.append([(v.co.x, v.co.z) for v in tri])
            else:
                uvs.append([(v.co.y, v.co.z) for v in tri])
            mats.append(f.material_index)
            widths.append(width)
    return (np.array(tris).reshape(-1, 3, 3), np.array(nrms).reshape(-1, 3, 3), np.array(uvs).reshape(-1, 3, 2),
            np.array(mats, dtype=np.int64), np.array(widths))


def export(parts, path):
    import bake
    import kit

    flat = [_flatten(p, bake) for p in parts]
    world = np.concatenate([f[0] for f in flat])
    normals = np.concatenate([f[1] for f in flat])
    widths = np.concatenate([f[4] for f in flat])
    ao, edge, piece, vis = bake.bake(world, normals, up=2, width=widths, views=bake.factorio_views(up=2))

    blob, views, accessors = bytearray(), [], []

    def add(array, kind, component, target):
        data = np.ascontiguousarray(array)
        while len(blob) % 4:
            blob.append(0)
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": data.nbytes, "target": target})
        blob.extend(data.tobytes())
        acc = {"bufferView": len(views) - 1, "componentType": component, "count": len(data), "type": kind}
        if kind == "VEC3" and component == 5126:
            acc["min"] = [float(c) for c in data.min(axis=0)]
            acc["max"] = [float(c) for c in data.max(axis=0)]
        accessors.append(acc)
        return len(accessors) - 1

    used, materials, meshes, nodes = {}, [], [], []
    names_seen = {}
    start = 0
    for part, (tris, nrm, uv, mat, _width) in zip(parts, flat):
        n = len(tris)
        sel = slice(start, start + n)
        start += n
        pivot = np.array(part.pivot.v)
        prims = []
        for m in sorted(set(mat.tolist())):
            name = part.mats[m]
            if name not in used:
                used[name] = len(materials)
                materials.append(_material(name, kit))
            pick = np.nonzero(mat == m)[0]
            local = (tris[pick] - pivot).reshape(-1, 3)
            rows = np.concatenate([
                np.stack([local[:, 0], local[:, 2], -local[:, 1]], axis=1),
                np.stack([nrm[pick].reshape(-1, 3)[:, 0], nrm[pick].reshape(-1, 3)[:, 2],
                          -nrm[pick].reshape(-1, 3)[:, 1]], axis=1),
                np.stack([uv[pick].reshape(-1, 2)[:, 0], 1.0 - uv[pick].reshape(-1, 2)[:, 1]], axis=1),
                np.stack([edge[sel][pick].reshape(-1), np.repeat(piece[sel][pick], 3)], axis=1),
                vis[sel][pick][..., 0:2].reshape(-1, 2),
                vis[sel][pick][..., 2:4].reshape(-1, 2),
                ao[sel][pick].reshape(-1, 1),
            ], axis=1).astype(np.float32)
            unique, inverse = np.unique(rows, axis=0, return_inverse=True)
            inverse = inverse.reshape(-1)
            colour = np.concatenate([np.ones((len(unique), 3), np.float32), unique[:, 14:15]], axis=1)
            attrs = {"POSITION": add(unique[:, 0:3], "VEC3", 5126, 34962),
                     "NORMAL": add(unique[:, 3:6], "VEC3", 5126, 34962),
                     "TEXCOORD_0": add(unique[:, 6:8], "VEC2", 5126, 34962),
                     "TEXCOORD_1": add(unique[:, 8:10], "VEC2", 5126, 34962),
                     "TEXCOORD_2": add(unique[:, 10:12], "VEC2", 5126, 34962),
                     "TEXCOORD_3": add(unique[:, 12:14], "VEC2", 5126, 34962),
                     "COLOR_0": add(colour, "VEC4", 5126, 34962)}
            prims.append({"attributes": attrs, "indices": add(inverse.astype(np.uint32), "SCALAR", 5125, 34963),
                          "material": used[name], "mode": 4})
        seen = names_seen.get(part.name, 0)
        names_seen[part.name] = seen + 1
        name = part.name if seen == 0 else "%s.%03d" % (part.name, seen)
        meshes.append({"name": name, "primitives": prims})
        node = {"name": name, "mesh": len(meshes) - 1}
        if any(pivot):
            node["translation"] = [float(pivot[0]), float(pivot[2]), float(-pivot[1])]
        nodes.append(node)
    while len(blob) % 4:
        blob.append(0)
    doc = {"asset": {"generator": GENERATOR, "version": "2.0"}, "scene": 0,
           "scenes": [{"name": "Scene", "nodes": list(range(len(nodes)))}], "nodes": nodes, "materials": materials,
           "meshes": meshes, "accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": len(blob)}]}
    if any("extensions" in m for m in materials):
        doc["extensionsUsed"] = ["KHR_materials_emissive_strength"]
    text = json.dumps(doc, separators=(",", ":")).encode()
    text += b" " * ((4 - len(text) % 4) % 4)
    total = 12 + 8 + len(text) + 8 + len(blob)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(text), 0x4E4F534A) + text)
        f.write(struct.pack("<II", len(blob), 0x004E4942) + bytes(blob))


def _material(name, kit):
    colour, rough, metal, emit, strength = kit.MATERIALS[name]
    alpha = kit.ALPHA.get(name, 1.0)
    m = {"name": name, "doubleSided": True,
         "pbrMetallicRoughness": {"baseColorFactor": [*kit.srgb_to_linear(colour), alpha], "metallicFactor": metal,
                                  "roughnessFactor": rough}}
    if name in kit.ALPHA:
        m["alphaMode"] = "BLEND"
    if emit:
        m["emissiveFactor"] = list(kit.srgb_to_linear(emit))
        if strength != 1:
            m["extensions"] = {"KHR_materials_emissive_strength": {"emissiveStrength": strength}}
    return m


def _report(name, built, committed):
    import trimesh
    out = []
    for path in (built, committed):
        scene = trimesh.load(path, force="scene")
        mesh = scene.to_geometry() if hasattr(scene, "to_geometry") else scene.dump(concatenate=True)
        out.append((len(mesh.faces), np.round(mesh.bounds, 3).tolist()))
    print("compare: %-26s here %6d tris %s" % (name, *out[0]))
    print("compare: %-26s .glb %6d tris %s" % ("", *out[1]))


def main():
    install()
    import kit
    import specs
    build = importlib.import_module("build")
    kit.export = export
    args = sys.argv[1:]
    compare = "--compare" in args
    out_dir = os.path.join(REPO, "client", "assets", "models")
    names = []
    for arg in args:
        if arg.startswith("--out="):
            out_dir = os.path.abspath(arg.split("=", 1)[1])
        elif arg != "--compare":
            names.append(arg)
    for module in build.MODULES:
        importlib.import_module(module)
    names = names or sorted(kit.REGISTRY)
    target = tempfile.mkdtemp(prefix="noblender") if compare else out_dir
    failed = 0
    for name in names:
        begun = time.time()
        try:
            parts = kit.as_parts(kit.REGISTRY[name]())
            path = os.path.join(target, name + ".glb")
            export(parts, path)
        except Exception:  # noqa: BLE001  (one model failing doesn't stop the rest)
            traceback.print_exc()
            print("noblender: FAIL %s" % name)
            failed += 1
            continue
        tris = sum(p.triangles() for p in parts)
        budget = specs.SPECS.get(name, {}).get("budget", 0)
        flag = "" if not budget or tris <= budget else "  OVER BUDGET (%d)" % budget
        print("noblender: %-28s %6d tris  %.1fs%s" % (name, tris, time.time() - begun, flag))
        if compare:
            _report(name, path, os.path.join(out_dir, name + ".glb"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

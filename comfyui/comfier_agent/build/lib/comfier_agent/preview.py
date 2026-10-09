"""Renders a still preview of a 3D result, for browsers that can't show the model itself.

Runs as its own process (``python preview.py MODEL OUT.jpg [SIZE]``) so a huge or broken mesh can't stall or
crash ComfyUI; the agent kills it if it takes too long. Needs numpy, Pillow and trimesh, which ComfyUI's 3D
nodes already pull in. The renderer is a small software rasterizer: no GPU, OpenGL or display required.
"""

from __future__ import annotations

import sys

import numpy as np

DEFAULT_SIZE = 1024
SUPERSAMPLE = 2
MARGIN = 0.06
FOV_DEG = 30.0
AZIMUTH_DEG = 30.0
ELEVATION_DEG = 20.0
MAX_FACES = 5_000_000
# Corners whose smoothed normal is further than this from the face's own are drawn flat, so hard edges stay hard.
CREASE_COS = np.cos(np.radians(40.0))
# Point clouds often have stray points far out; frame the bulk of them instead.
POINT_FRAME_PERCENTILE = 0.5
# Candidate pixels tested per batch; bounds memory whatever the triangle sizes.
BATCH_PIXELS = 1 << 22
CLAY = np.array([0.72, 0.70, 0.67])
BG_TOP = np.array([0.96, 0.96, 0.97])
BG_BOTTOM = np.array([0.85, 0.86, 0.88])
JPEG_QUALITY = 90


class Surface:
    """One mesh's triangles and what colours them."""

    def __init__(self, vertices, faces, normals, colors=None, uv=None, texture=None, tint=None):
        self.vertices = vertices
        self.faces = faces
        self.normals = normals
        self.colors = colors  # per-vertex linear RGB, or None
        self.uv = uv
        self.texture = texture  # linear RGB array (H, W, 3), or None
        self.tint = CLAY if tint is None else tint


def render(path: str, out_path: str, size: int = DEFAULT_SIZE) -> None:
    from PIL import Image

    surfaces, points = load(path)
    if not surfaces and points is None:
        raise ValueError("no renderable geometry")
    image = Renderer(surfaces, points, size * SUPERSAMPLE).draw()
    pil = Image.fromarray(to_srgb8(image), "RGB")
    if SUPERSAMPLE > 1:
        pil = pil.resize((size, size), Image.LANCZOS)
    pil.save(out_path, "JPEG", quality=JPEG_QUALITY, optimize=True)


def load(path: str):
    import trimesh

    scene = trimesh.load(path, force="scene", process=False)
    surfaces, clouds = [], []
    for node in scene.graph.nodes_geometry:
        transform, name = scene.graph[node]
        geom = scene.geometry[name]
        if isinstance(geom, trimesh.Trimesh) and len(geom.faces):
            surfaces.append(surface_from(geom, transform))
        elif isinstance(geom, trimesh.PointCloud) and len(geom.vertices):
            clouds.append(points_from(geom, transform))
    if sum(len(s.faces) for s in surfaces) > MAX_FACES:
        raise ValueError("too many faces to preview")
    points = None
    if clouds:
        points = (np.concatenate([c[0] for c in clouds]), np.concatenate([c[1] for c in clouds]))
    return surfaces, points


def transform_points(points, matrix):
    return points @ matrix[:3, :3].T + matrix[:3, 3]


def surface_from(mesh, transform) -> Surface:
    vertices = transform_points(np.asarray(mesh.vertices, dtype=np.float64), transform)
    faces = np.asarray(mesh.faces, dtype=np.int64)
    # Normals take the inverse transpose, so non-uniformly scaled nodes still light correctly.
    local = np.asarray(mesh.vertices, dtype=np.float64)
    normals = vertex_normals(mesh, local, faces) @ np.linalg.pinv(transform[:3, :3])
    surface = Surface(vertices, faces, normals)
    visual = mesh.visual
    kind = getattr(visual, "kind", None)
    if kind == "texture":
        apply_material(surface, visual)
    elif kind == "vertex":
        surface.colors = to_linear(np.asarray(visual.vertex_colors)[:, :3] / 255.0)
    elif kind == "face":
        # Split faces so each corner carries its face's colour.
        face_rgb = to_linear(np.asarray(visual.face_colors)[:, :3] / 255.0)
        surface.vertices = surface.vertices[faces].reshape(-1, 3)
        surface.normals = surface.normals[faces].reshape(-1, 3)
        surface.colors = np.repeat(face_rgb, 3, axis=0)
        surface.faces = np.arange(len(faces) * 3).reshape(-1, 3)
    return surface


def vertex_normals(mesh, vertices, faces):
    """The file's own normals, else area-weighted ones. Not trimesh's: without scipy it computes them slowly."""
    if "vertex_normals" in mesh._cache:
        return np.asarray(mesh.vertex_normals, dtype=np.float64)
    corners = vertices[faces]
    face_normals = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
    normals = np.zeros_like(vertices)
    for corner in range(3):
        np.add.at(normals, faces[:, corner], face_normals)
    return normals


def apply_material(surface: Surface, visual) -> None:
    material = getattr(visual, "material", None)
    factor = getattr(material, "baseColorFactor", None)
    if factor is None:
        factor = getattr(material, "diffuse", None)
    if factor is not None:
        factor = np.asarray(factor, dtype=np.float64)[:3]
        surface.tint = to_linear(factor / 255.0 if factor.max() > 1.0 else factor)
    image = getattr(material, "baseColorTexture", None)
    if image is None:
        image = getattr(material, "image", None)
    uv = getattr(visual, "uv", None)
    if image is not None and uv is not None and len(uv) == len(surface.vertices):
        texture = np.asarray(image.convert("RGB"), dtype=np.float64) / 255.0
        surface.texture = to_linear(texture)
        surface.uv = np.asarray(uv, dtype=np.float64)
        if factor is None:
            surface.tint = np.ones(3)


def points_from(cloud, transform):
    vertices = transform_points(np.asarray(cloud.vertices, dtype=np.float64), transform)
    colors = getattr(cloud, "colors", None)
    if colors is not None and len(colors) == len(vertices):
        rgb = to_linear(np.asarray(colors)[:, :3] / 255.0)
    else:
        rgb = np.tile(CLAY, (len(vertices), 1))
    return vertices, rgb


def to_linear(srgb):
    return np.power(np.clip(srgb, 0.0, 1.0), 2.2)


def to_srgb8(linear):
    return (np.power(np.clip(linear, 0.0, 1.0), 1 / 2.2) * 255.0 + 0.5).astype(np.uint8)


class Renderer:
    """Frames the model from the front-right, a little above, and shades it with a key and fill light."""

    def __init__(self, surfaces, points, size):
        self.surfaces = surfaces
        self.points = points
        self.size = size
        everything = [s.vertices for s in surfaces] + ([points[0]] if points is not None else [])
        self.setup_camera(np.concatenate(everything), trim=POINT_FRAME_PERCENTILE if points is not None else 0.0)

    def setup_camera(self, vertices, trim=0.0):
        lo, hi = vertices.min(axis=0), vertices.max(axis=0)
        center = (lo + hi) / 2
        radius = max(float(np.linalg.norm(vertices - center, axis=1).max()), 1e-9)
        az, el = np.radians(AZIMUTH_DEG), np.radians(ELEVATION_DEG)
        # glTF faces +Z with +Y up; ComfyUI's 3D nodes follow it.
        toward_eye = np.array([np.sin(az) * np.cos(el), np.sin(el), np.cos(az) * np.cos(el)])
        self.eye = center + toward_eye * radius / np.sin(np.radians(FOV_DEG) / 2) * 1.1
        self.forward = -toward_eye
        self.right = np.cross(self.forward, [0.0, 1.0, 0.0])
        self.right /= np.linalg.norm(self.right)
        self.up = np.cross(self.right, self.forward)
        self.key = unit(-0.5 * self.right + 0.8 * self.up - 0.6 * self.forward)
        self.fill = unit(0.7 * self.right + 0.1 * self.up - 0.5 * self.forward)

        sx, sy, _ = self.camera_space(vertices)
        (left, right), (bottom, top) = np.percentile(sx, [trim, 100 - trim]), np.percentile(sy, [trim, 100 - trim])
        self.cx, self.cy = (left + right) / 2, (bottom + top) / 2
        extent = max(right - left, top - bottom, 1e-12)
        self.scale = self.size * (1 - 2 * MARGIN) / extent

    def camera_space(self, vertices):
        rel = vertices - self.eye
        z = np.maximum(rel @ self.forward, 1e-9)
        return (rel @ self.right) / z, (rel @ self.up) / z, z

    def project(self, vertices):
        sx, sy, z = self.camera_space(vertices)
        half = self.size / 2
        return (sx - self.cx) * self.scale + half, half - (sy - self.cy) * self.scale, z

    def draw(self):
        n = self.size
        self.zbuf = np.full(n * n, np.inf)
        self.surface_buf = np.full(n * n, -1, dtype=np.int32)
        self.face_buf = np.zeros(n * n, dtype=np.int64)
        self.color_buf = np.zeros((n * n, 3))
        for index, surface in enumerate(self.surfaces):
            self.rasterize(index, surface)
        if self.points is not None:
            self.splat(*self.points)

        rows = np.linspace(0, 1, n)[:, None]
        image = (BG_TOP * (1 - rows) + BG_BOTTOM * rows)[:, None, :].repeat(n, axis=1).reshape(-1, 3)
        for index, surface in enumerate(self.surfaces):
            pixels = np.nonzero(self.surface_buf == index)[0]
            if len(pixels):
                image[pixels] = self.shade(surface, pixels)
        dots = np.isfinite(self.zbuf) & (self.surface_buf == -1)
        image[dots] = self.color_buf[dots]
        return image.reshape(n, n, 3)

    def rasterize(self, index, surface):
        px, py, pz = self.project(surface.vertices)
        tri = surface.faces
        x, y, z = px[tri], py[tri], pz[tri]
        n = self.size
        x0 = np.clip(np.floor(x.min(axis=1)), 0, n - 1).astype(np.int64)
        x1 = np.clip(np.ceil(x.max(axis=1)), 0, n - 1).astype(np.int64)
        y0 = np.clip(np.floor(y.min(axis=1)), 0, n - 1).astype(np.int64)
        y1 = np.clip(np.ceil(y.max(axis=1)), 0, n - 1).astype(np.int64)
        area = (x[:, 1] - x[:, 0]) * (y[:, 2] - y[:, 0]) - (x[:, 2] - x[:, 0]) * (y[:, 1] - y[:, 0])
        visible = (np.abs(area) > 1e-12) & (x.max(axis=1) >= 0) & (x.min(axis=1) <= n) & \
                  (y.max(axis=1) >= 0) & (y.min(axis=1) <= n)
        span = np.maximum(x1 - x0, y1 - y0) + 1
        # Group triangles by bounding-box size so each batch tests a fixed square of pixels per triangle.
        bucket = np.ceil(np.log2(np.maximum(span, 1))).astype(np.int64)
        for b in np.unique(bucket[visible]):
            ids = np.nonzero(visible & (bucket == b))[0]
            side = 1 << int(b)
            per_batch = max(1, BATCH_PIXELS // (side * side))
            oy, ox = np.divmod(np.arange(side * side), side)
            for start in range(0, len(ids), per_batch):
                batch = ids[start:start + per_batch]
                cols = x0[batch, None] + ox
                rows = y0[batch, None] + oy
                inside = (cols <= x1[batch, None]) & (rows <= y1[batch, None])
                l0, l1, l2 = barycentric(x[batch, None], y[batch, None], area[batch, None], cols + 0.5, rows + 0.5)
                inside &= (l0 >= 0) & (l1 >= 0) & (l2 >= 0)
                tri_z = z[batch]
                depth = 1.0 / (l0 / tri_z[:, :1] + l1 / tri_z[:, 1:2] + l2 / tri_z[:, 2:3])
                which, cell = np.nonzero(inside)
                pixel = rows[which, cell] * n + cols[which, cell]
                self.write(pixel, depth[which, cell], index, batch[which])

    def write(self, pixel, depth, surface, face=None, color=None):
        order = np.lexsort((depth, pixel))
        pixel, depth = pixel[order], depth[order]
        first = np.ones(len(pixel), dtype=bool)
        first[1:] = pixel[1:] != pixel[:-1]
        pixel, depth, order = pixel[first], depth[first], order[first]
        nearer = depth < self.zbuf[pixel]
        pixel, order = pixel[nearer], order[nearer]
        self.zbuf[pixel] = depth[nearer]
        self.surface_buf[pixel] = surface
        if face is not None:
            self.face_buf[pixel] = face[order]
        if color is not None:
            self.color_buf[pixel] = color[order]

    def splat(self, vertices, colors):
        px, py, pz = self.project(vertices)
        n = self.size
        radius = max(1, round(n / 600))
        offsets = np.arange(-radius, radius + 1)
        oy, ox = [g.ravel() for g in np.meshgrid(offsets, offsets, indexing="ij")]
        keep = ox * ox + oy * oy <= radius * radius
        ox, oy = ox[keep], oy[keep]
        cols = (np.floor(px)[:, None] + ox).astype(np.int64)
        rows = (np.floor(py)[:, None] + oy).astype(np.int64)
        valid = (cols >= 0) & (cols < n) & (rows >= 0) & (rows < n)
        which, cell = np.nonzero(valid)
        pixel = rows[which, cell] * n + cols[which, cell]
        self.write(pixel, pz[which], -1, color=colors[which])

    def shade(self, surface, pixels):
        n = self.size
        face = self.face_buf[pixels]
        tri = surface.faces[face]
        px, py, pz = self.project(surface.vertices)
        x, y, z = px[tri], py[tri], pz[tri]
        area = (x[:, 1] - x[:, 0]) * (y[:, 2] - y[:, 0]) - (x[:, 2] - x[:, 0]) * (y[:, 1] - y[:, 0])
        cols, rows = pixels % n + 0.5, pixels // n + 0.5
        l0, l1, l2 = barycentric(x, y, area, cols, rows)
        # Perspective-correct weights so textures don't swim across large triangles.
        w = np.stack([l0, l1, l2], axis=1) / z
        w /= w.sum(axis=1, keepdims=True)

        def interpolate(values):
            return np.einsum("pk,pkc->pc", w, values[tri])

        position = interpolate(surface.vertices)
        corners = surface.vertices[tri]
        flat = unit_rows(np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0]))
        corner_normals = surface.normals[tri]
        corner_normals /= np.maximum(np.linalg.norm(corner_normals, axis=2, keepdims=True), 1e-12)
        creased = np.abs(np.einsum("pkc,pc->pk", corner_normals, flat)) < CREASE_COS
        corner_normals[creased] = np.broadcast_to(flat[:, None, :], corner_normals.shape)[creased]
        normal = unit_rows(np.einsum("pk,pkc->pc", w, corner_normals))
        to_eye = self.eye - position
        # Light both sides: generated meshes often have flipped or open faces.
        normal *= np.where(np.einsum("pc,pc->p", normal, to_eye) < 0, -1.0, 1.0)[:, None]

        if surface.texture is not None:
            albedo = sample(surface.texture, interpolate(surface.uv)) * surface.tint
        elif surface.colors is not None:
            albedo = interpolate(surface.colors)
        else:
            albedo = np.tile(surface.tint, (len(pixels), 1))

        light = 0.32 + 0.68 * np.clip(normal @ self.key, 0, None) + 0.22 * np.clip(normal @ self.fill, 0, None)
        return albedo * light[:, None]


def barycentric(x, y, area, cols, rows):
    """Weights of pixel centres against triangle corners. x and y end in a corner axis of 3 and, like area,
    broadcast against cols and rows."""
    l0 = ((x[..., 1] - cols) * (y[..., 2] - rows) - (x[..., 2] - cols) * (y[..., 1] - rows)) / area
    l1 = ((x[..., 2] - cols) * (y[..., 0] - rows) - (x[..., 0] - cols) * (y[..., 2] - rows)) / area
    return l0, l1, 1.0 - l0 - l1


def sample(texture, uv):
    h, w = texture.shape[:2]
    u = np.mod(uv[:, 0], 1.0)
    v = np.mod(uv[:, 1], 1.0)
    cols = np.clip((u * w).astype(np.int64), 0, w - 1)
    rows = np.clip(((1.0 - v) * h).astype(np.int64), 0, h - 1)
    return texture[rows, cols]


def unit(vector):
    return vector / np.linalg.norm(vector)


def unit_rows(vectors):
    return vectors / np.maximum(np.linalg.norm(vectors, axis=1, keepdims=True), 1e-12)


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print("usage: preview.py MODEL OUT.jpg [SIZE]", file=sys.stderr)
        return 2
    size = int(argv[3]) if len(argv) == 4 else DEFAULT_SIZE
    try:
        render(argv[1], argv[2], size)
    except Exception as exc:  # noqa: BLE001 - the agent only needs to know it didn't work
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

// Region geometry: pack the SAM masks into one RGBA texture (a channel per region) and place
// each region in 3D: mask centroid, at the median depth of the splats whose centres project
// inside the mask through the capture intrinsics.
import * as THREE from 'three';

/** Masks (decoded, RG bytes) -> one RGBA texture, R/G/B = region 0/1/2. Missing -> soft ellipse in the box. */
export function packMasks(decoded, list, aspect) {
  const first = [...(decoded?.values() ?? [])][0];
  const width = first ? first.width : 512;
  const height = first ? first.height : Math.max(1, Math.round(512 / aspect));
  const data = new Uint8Array(width * height * 4);
  list.forEach((r, ch) => {
    if (ch > 2) return;
    const m = decoded?.get(r.id);
    if (m) {
      const sx = m.width / width;
      const sy = m.height / height;
      for (let y = 0; y < height; y++) {
        const my = Math.min(m.height - 1, Math.floor((y + 0.5) * sy));
        for (let x = 0; x < width; x++) {
          const mx = Math.min(m.width - 1, Math.floor((x + 0.5) * sx));
          data[(y * width + x) * 4 + ch] = m.data[(my * m.width + mx) * 2];
        }
      }
    } else {
      // No mask: a soft ellipse inside the box (never a rectangle).
      const { x: bx, y: by, w: bw, h: bh } = r.box;
      const cx = (bx + bw / 2) * width;
      const cy = (by + bh / 2) * height;
      const rx = Math.max(1, bw * width * 0.42);
      const ry = Math.max(1, bh * height * 0.42);
      for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
          const d = Math.hypot((x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry);
          const v = Math.min(1, Math.max(0, (1.12 - d) / 0.24));
          data[(y * width + x) * 4 + ch] = Math.round(255 * v * v * (3 - 2 * v));
        }
      }
    }
  });
  const tex = new THREE.DataTexture(data, width, height, THREE.RGBAFormat, THREE.UnsignedByteType);
  tex.flipY = false; // row 0 = top of the photo, like the masks
  tex.minFilter = THREE.LinearFilter;
  tex.magFilter = THREE.LinearFilter;
  tex.generateMipmaps = false;
  tex.wrapS = tex.wrapT = THREE.ClampToEdgeWrapping;
  tex.needsUpdate = true;
  return { tex, data, width, height };
}

/** Mask centroid in uv (top-left origin), snapped onto the mask if it falls in a gap. */
function centroid(pack, ch) {
  const { data, width, height } = pack;
  let sx = 0;
  let sy = 0;
  let n = 0;
  for (let y = 0; y < height; y += 2) {
    for (let x = 0; x < width; x += 2) {
      if (data[(y * width + x) * 4 + ch] > 127) {
        sx += x;
        sy += y;
        n++;
      }
    }
  }
  if (!n) return null;
  let cx = sx / n;
  let cy = sy / n;
  const at = (x, y) => data[(Math.round(y) * width + Math.round(x)) * 4 + ch];
  if (at(cx, cy) <= 127) {
    let best = Infinity;
    let bx = cx;
    let by = cy;
    for (let y = 0; y < height; y += 3) {
      for (let x = 0; x < width; x += 3) {
        if (data[(y * width + x) * 4 + ch] <= 127) continue;
        const d = (x - cx) ** 2 + (y - cy) ** 2;
        if (d < best) {
          best = d;
          bx = x;
          by = y;
        }
      }
    }
    cx = bx;
    cy = by;
  }
  return { u: (cx + 0.5) / width, v: (cy + 0.5) / height, area: (n * 4) / (width * height) };
}

/**
 * Anchor (capture-camera coords: x right, y down, z forward) and depth gate for one region.
 * samples: { n, z, nx, ny, op } from the splat (nx, ny in [-1, 1] across the photo).
 * Without samples (flat photo) the anchor sits on the photo plane at `planeD`.
 */
export function placeRegion(pack, ch, region, samples, tanX, tanY, planeD) {
  const c = centroid(pack, ch) ?? { u: region.box.x + region.box.w / 2, v: region.box.y + region.box.h / 2, area: 0 };
  let depth = planeD;
  let lo = 1e-3;
  let hi = 1e4;
  let count = 0;
  if (samples) {
    const { data, width, height } = pack;
    const zs = [];
    for (let k = 0; k < samples.n; k++) {
      const z = samples.z[k];
      if (!(z > 0) || samples.op[k] < 0.25) continue;
      const nx = samples.nx[k];
      const ny = samples.ny[k];
      if (nx <= -1 || nx >= 1 || ny <= -1 || ny >= 1) continue;
      const px = Math.floor((nx * 0.5 + 0.5) * width);
      const py = Math.floor((ny * 0.5 + 0.5) * height);
      if (data[(py * width + px) * 4 + ch] > 140) zs.push(z);
    }
    count = zs.length;
    if (count > 20) {
      zs.sort((a, b) => a - b);
      const q = (p) => zs[Math.min(count - 1, Math.floor(count * p))];
      depth = q(0.5);
      // Gate: the object's own depth range; SHARP's back layer and background seen through
      // gaps sit well behind it. Generous, so thin parts (limbs, a leash, the far end of a
      // walker) stay with the object.
      lo = q(0.01) * 0.88;
      hi = Math.max(q(0.93) * 1.1, depth * 1.3);
    }
  }
  const nx = c.u * 2 - 1;
  const ny = c.v * 2 - 1;
  return {
    anchor: new THREE.Vector3(nx * tanX * depth, ny * tanY * depth, depth),
    gate: new THREE.Vector2(lo, hi),
    uv: [c.u, c.v],
    depth,
    count,
    area: c.area,
  };
}

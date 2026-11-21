import * as THREE from 'three';
import { dyno } from '@sparkjsdev/spark';

// One GPU program over every gaussian of the open photo (ported from wayback's memoryShader).
// Splat coordinates are the capture camera's own: eye at the origin, x right, y down, z forward.
// Every effect slides a splat along its own ray from that eye (or, for the subject, along the
// subject's centre ray), so from the capture viewpoint the picture holds and only depth moves.
//
//  - Reveal: black until a warm band sweeping near -> far (log depth) reaches each splat.
//  - Focus: one RGBA mask texture, one channel per region. Each splat centre is projected through
//    the capture intrinsics to uv and the mask is sampled there; a depth gate drops splats far
//    behind the object (SHARP's back layer). w.xyz are per-region focus weights (springs), so
//    switching markers is a crossfade with no texture swaps.
//      subject: rigid move toward the camera along its centre ray (lift x depth), light lift.
//      the rest: recedes along its rays, desaturates and settles at ~12-20% brightness, more
//      light close to the subject in 3D (a wide pool); occluders in front turn translucent.
//  - Remove (rw, rh: per-region weights): the scene stays lit. The distraction glows briefly
//    (rh, a pulse driven from JS) so you see where it is, then recedes: pushed back along its
//    rays, desaturated, faded to ~20% and its splats drift apart a little. A preview of the
//    shot without it.

export function makeFocusUniforms(maskTex) {
  return {
    tanX: dyno.dynoFloat(0.5),
    tanY: dyno.dynoFloat(0.375),
    logNear: dyno.dynoFloat(0),
    logFar: dyno.dynoFloat(3),
    front: dyno.dynoFloat(-10), // reveal front in normalized log depth; > 1 + band = fully shown
    band: dyno.dynoFloat(0.09),
    glowColor: dyno.dynoVec3(new THREE.Vector3(1.0, 0.66, 0.36)),
    glowStrength: dyno.dynoFloat(0.55),
    fade: dyno.dynoFloat(1),
    mask: dyno.dynoSampler2D(maskTex),
    hasMask: dyno.dynoFloat(0),
    grow: dyno.dynoFloat(0.012), // radius of the fringe ring, in uv across the photo's width
    w: dyno.dynoVec3(new THREE.Vector3()), // focus weight per region
    rw: dyno.dynoVec3(new THREE.Vector3()), // remove (dissolve) weight per region
    rh: dyno.dynoVec3(new THREE.Vector3()), // remove highlight pulse per region
    anc0: dyno.dynoVec3(new THREE.Vector3(0, 0, 3)), // region anchors (file coords, at median depth)
    anc1: dyno.dynoVec3(new THREE.Vector3(0, 0, 3)),
    anc2: dyno.dynoVec3(new THREE.Vector3(0, 0, 3)),
    gate0: dyno.dynoVec2(new THREE.Vector2(1e-3, 1e4)), // z range that counts as the object
    gate1: dyno.dynoVec2(new THREE.Vector2(1e-3, 1e4)),
    gate2: dyno.dynoVec2(new THREE.Vector2(1e-3, 1e4)),
    lift: dyno.dynoFloat(0.09), // subject moves this fraction of its depth toward the camera
    recede: dyno.dynoFloat(0.15), // everything else moves this fraction back along its ray
    boost: dyno.dynoFloat(0.12), // subject light lift
    floorFar: dyno.dynoFloat(0.12), // brightness of the rest, far from the subject
    floorNear: dyno.dynoFloat(0.2), // brightness of the rest at the subject's depth, near it
    pool: dyno.dynoFloat(2.2), // radius of the wide spatial falloff, x the subject's depth
    falloff: dyno.dynoFloat(0.55), // width of the depth falloff, in log depth
  };
}

export function makeFocusModifier(u) {
  const inTypes = { gsplat: dyno.Gsplat };
  for (const [k, v] of Object.entries(u)) inTypes[k] = v.type;

  return dyno.dynoBlock({ gsplat: dyno.Gsplat }, { gsplat: dyno.Gsplat }, ({ gsplat }) => {
    const program = new dyno.Dyno({
      inTypes,
      outTypes: { gsplat: dyno.Gsplat },
      statements: ({ inputs: i, outputs: o }) =>
        dyno.unindentLines(/* glsl */ `
        ${o.gsplat} = ${i.gsplat};
        vec3 c = ${i.gsplat}.center;
        vec3 sc = ${i.gsplat}.scales;
        vec4 col = ${i.gsplat}.rgba;
        float dist = max(length(c), 1e-5);
        float z = c.z;
        vec2 ndc = c.xy / max(z, 1e-4) / vec2(${i.tanX}, ${i.tanY});
        bool ahead = z > 1e-3;
        bool inFrame = ahead && abs(ndc.x) < 1.0 && abs(ndc.y) < 1.0;

        // Reveal from darkness: a warm band sweeps outward through (log) depth.
        float lf = clamp((log(dist) - ${i.logNear}) / max(${i.logFar} - ${i.logNear}, 1e-3), 0.0, 1.0);
        float bw = max(${i.band}, 1e-3);
        float delta = ${i.front} - lf;
        float reveal = smoothstep(-bw, 0.5 * bw, delta);
        float gq = (delta - 0.25 * bw) / bw;
        float glow = exp(-gq * gq) * ${i.glowStrength};

        // Which region(s) is this splat part of? Mask lookup at its capture-camera uv.
        // m: the mask at this splat. mb: the mask averaged on a ring around it, a soft "next to
        // the subject" signal used to shade the fringe (SHARP's soft silhouette splats would
        // otherwise glow like a rim against the dark).
        vec3 m = vec3(0.0);
        vec3 mb = vec3(0.0);
        if (inFrame && ${i.hasMask} > 0.5) {
          vec2 muv = ndc * 0.5 + 0.5;
          vec2 g = vec2(${i.grow}, ${i.grow} * ${i.tanX} / ${i.tanY});
          m = textureLod(${i.mask}, muv, 0.0).rgb;
          for (int yy = -1; yy <= 1; yy++) {
            for (int xx = -1; xx <= 1; xx++) {
              if (xx != 0 || yy != 0) mb += textureLod(${i.mask}, muv + vec2(float(xx), float(yy)) * g, 0.0).rgb;
            }
          }
          mb *= 0.125;
        }
        vec3 lo = vec3(${i.gate0}.x, ${i.gate1}.x, ${i.gate2}.x);
        vec3 hi = vec3(${i.gate0}.y, ${i.gate1}.y, ${i.gate2}.y);
        vec3 zz = vec3(z);
        vec3 gate = smoothstep(lo * 0.8, lo, zz) * (1.0 - smoothstep(hi, hi * 1.2, zz));
        vec3 wv = ${i.w};
        vec3 sv = smoothstep(vec3(0.4), vec3(0.66), m) * gate * wv; // weighted subject amount
        float wsum = wv.x + wv.y + wv.z;
        float F = clamp(wsum, 0.0, 1.0);                  // how focused the view is
        float s = clamp(sv.x + sv.y + sv.z, 0.0, 1.0);    // this splat as subject
        float o = max(F - s, 0.0);                        // this splat as "everything else"
        float sel = s / max(F, 1e-4);                     // subject-ness, independent of weight
        // Only confidently selected splats get the light; half-selected silhouette splats (soft
        // mask edge, or SHARP splats straddling the depth step) go dark, so no halo or rim.
        float litK = F * smoothstep(0.5, 0.95, sel);

        vec3 A0 = ${i.anc0};
        vec3 A1 = ${i.anc1};
        vec3 A2 = ${i.anc2};
        vec3 anc = (A0 * wv.x + A1 * wv.y + A2 * wv.z) / max(wsum, 1e-4);
        float dS = max(length(anc), 1e-3);

        // Subject: rigid lift toward the eye along its own centre ray, so it grows a little on
        // screen. Rest: slides back along its rays (scale follows, apparent size holds).
        float kr = 1.0 + ${i.recede} * o;
        vec3 pos = c * kr - ${i.lift} * (A0 * sv.x + A1 * sv.y + A2 * sv.z);
        vec3 s3 = sc * kr;

        // Light: the rest desaturates and falls toward black with 3D distance from the
        // subject (things at its depth, next to it, keep a little light); the subject lifts.
        // Mostly by depth (the subject's depth layer stays faintly visible across the frame),
        // with only a very wide spatial term: a tight pool would hug the silhouette like a rim.
        float d3 = length(c - anc) / (dS * ${i.pool});
        float wide = exp(-d3 * d3);
        float dz = log(dist / dS) / ${i.falloff};
        float nearZ = exp(-dz * dz);
        float lvl = mix(${i.floorFar}, ${i.floorNear}, nearZ * mix(0.5, 1.0, wide));
        float ringW = dot(mb, wv) / max(wsum, 1e-4);      // ring average of the focused mask(s)
        lvl *= 1.0 - 0.6 * clamp(smoothstep(0.1, 0.6, ringW) - sel, 0.0, 1.0); // contact shadow
        // SHARP's silhouette splats are big and soft: against a bright background they blend
        // in, against the dark they glow like a rim. Near the mask edge, tighten them.
        float edgeK = litK * (1.0 - smoothstep(0.5, 0.85, ringW));
        vec3 rgb = col.rgb;
        float lum = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
        vec3 rest = mix(rgb, vec3(lum), 0.5) * lvl;
        vec3 lit = rgb * (1.0 + ${i.boost}) + vec3(0.022, 0.016, 0.007);
        rgb = mix(rgb, rest, F - litK);
        rgb = mix(rgb, lit, litK);
        rgb += ${i.glowColor} * glow * (1.0 - F);

        float a = col.a * reveal * (1.0 - 0.7 * edgeK);

        // Remove: membership is generous (mask or its ring) so no silhouette is left behind.
        vec3 gr = smoothstep(vec3(0.25), vec3(0.6), max(m, mb)) * gate;
        float rem = clamp(dot(gr, ${i.rw}), 0.0, 1.0);
        float hl = clamp(dot(gr, ${i.rh}), 0.0, 1.0);
        if (rem > 0.0 || hl > 0.0) {
          float hsh = fract(sin(dot(c, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
          vec3 jit = vec3(fract(hsh * 13.17), fract(hsh * 71.73), fract(hsh * 29.31)) - 0.5;
          pos = pos * (1.0 + 0.12 * rem) + jit * dist * 0.012 * rem;
          s3 *= 1.0 + 0.06 * rem;
          float rl = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
          rgb = mix(rgb, vec3(rl) * 0.9, 0.85 * rem);
          rgb = mix(rgb, rgb * 1.3 + ${i.glowColor} * 0.28, hl);
          a *= 1.0 - 0.8 * rem;
        }
        s3 *= 1.0 - 0.18 * edgeK;
        // Occluders well in front of the subject turn translucent so they don't block it.
        float before = 1.0 - smoothstep(0.55, 0.85, dist / dS);
        a *= 1.0 - 0.65 * o * before;
        // No hard frame: splats dissolve into the dark at the photo's edges.
        if (ahead) {
          float edge = 1.0 - max(abs(ndc.x), abs(ndc.y));
          a *= smoothstep(-0.005, 0.06, edge);
        }

        ${o.gsplat}.center = pos;
        ${o.gsplat}.scales = s3;
        ${o.gsplat}.rgba = vec4(rgb, a * ${i.fade});
      `),
    });
    return { gsplat: program.apply({ gsplat, ...u }).gsplat };
  });
}

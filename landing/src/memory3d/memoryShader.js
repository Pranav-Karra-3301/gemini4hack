import * as THREE from 'three';
import { dyno } from '@sparkjsdev/spark';

// Adapted from Wayback (src/memoryShader.js). One GPU program runs over every gaussian of the
// memory. Wayback slides splats along their ray from the capture camera; here they stay at their
// true depth (from the capture eye that already looks exactly like the photo), and the program
// carries Gemini's light edit instead, weighted by each splat's distance from the capture eye:
//   people:     near splats gain exposure (EV), with a soft falloff around the subject depth
//   warmth:     a gentle warm white balance over everything
//   background: far splats lose a little exposure

export function makeMemoryUniforms() {
  return {
    fade: dyno.dynoFloat(1), // overall opacity
    logNear: dyno.dynoFloat(0), // log distance of the near / middle / far of the scene
    logMid: dyno.dynoFloat(1),
    logFar: dyno.dynoFloat(3),
    eye: dyno.dynoVec3(new THREE.Vector3()),
    maxDist: dyno.dynoFloat(1e5),
    people: dyno.dynoFloat(0), // EV on the near subject
    warmth: dyno.dynoFloat(0), // white balance, -100..100
    background: dyno.dynoFloat(0), // EV on the far field
    edit: dyno.dynoFloat(1), // 0 = original, 1 = edited (hold to compare)
  };
}

export function makeMemoryModifier(u) {
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
        vec4 col = ${i.gsplat}.rgba;

        // How far "into" the scene this splat is: 0 nearest ... 1 farthest (log).
        float dist = max(length(c - ${i.eye}), 1e-5);
        float span = max(${i.logFar} - ${i.logNear}, 1e-3);
        float lf = clamp((log(dist) - ${i.logNear}) / span, 0.0, 1.0);
        float lm = clamp((${i.logMid} - ${i.logNear}) / span, 0.0, 1.0);
        float nearK = 1.0 - smoothstep(lm - 0.12, lm + 0.08, lf);
        float farK = smoothstep(lm + 0.04, min(lm + 0.4, 1.0), lf);

        // Gemini's edit, in linear light.
        float E = ${i.edit};
        vec3 lin = pow(max(col.rgb, vec3(0.0)), vec3(2.2));
        lin *= exp2(E * (${i.people} * nearK + ${i.background} * farK));
        float w = E * ${i.warmth} / 100.0;
        lin *= vec3(1.0 + 0.75 * w, 1.0 + 0.1 * w, 1.0 - 0.95 * w);
        // Soft shoulder so brightened faces roll off instead of clipping (edited splats only).
        const float k = 0.62;
        vec3 over = max(lin - k, 0.0);
        vec3 sh = min(lin, vec3(k)) + (1.0 - k) * (1.0 - exp(-over / (1.0 - k)));
        lin = mix(lin, sh, E * nearK * clamp(${i.people} / 0.6, 0.0, 1.0));
        vec3 rgb = pow(lin, vec3(1.0 / 2.2));

        float a = col.a * ${i.fade};
        if (dist > ${i.maxDist}) a = 0.0;
        ${o.gsplat}.rgba = vec4(rgb, a);
      `),
    });
    return { gsplat: program.apply({ gsplat, ...u }).gsplat };
  });
}

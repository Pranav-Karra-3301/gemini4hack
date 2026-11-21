// Paper Shaders (vanilla ShaderMount). One distinct, matte artwork per section,
// mounted lazily by main.js. Each returns { dispose(), scroll(p) } (p: -1 entering,
// 0 centred, 1 leaving) so the art drifts with scroll. Unicorn scenes replace the
// hero / depth / desk / voice layers when their JSON exists.
import {
  ShaderMount,
  ShaderFitOptions,
  meshGradientFragmentShader,
  grainGradientFragmentShader,
  GrainGradientShapes,
  warpFragmentShader,
  WarpPatterns,
  simplexNoiseFragmentShader,
  colorPanelsFragmentShader,
  getShaderColorFromString,
  getShaderNoiseTexture,
} from '@paper-design/shaders';

const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const rgba = (c) => getShaderColorFromString(c);

const sizing = (over = {}) => ({
  u_fit: ShaderFitOptions.cover,
  u_scale: 1,
  u_rotation: 0,
  u_originX: 0.5,
  u_originY: 0.5,
  u_offsetX: 0,
  u_offsetY: 0,
  u_worldWidth: 0,
  u_worldHeight: 0,
  ...over,
});

let noisePromise;
function noise() {
  noisePromise ??= new Promise((resolve) => {
    const img = getShaderNoiseTexture();
    if (!img) return resolve(undefined);
    if (img.complete) return resolve(img);
    img.onload = () => resolve(img);
    img.onerror = () => resolve(undefined);
  });
  return noisePromise;
}

function mount(el, frag, uniforms, speed, { minPixelRatio = 0.6, maxPixelCount = 1280 * 800 } = {}) {
  try {
    return new ShaderMount(el, frag, uniforms, { premultipliedAlpha: true, alpha: true }, reduced ? 0 : speed, 0, minPixelRatio, maxPixelCount);
  } catch (err) {
    console.warn('[shaders] could not mount', err);
    return null;
  }
}

// Wraps a mount with a scroll hook that maps section progress onto a few uniforms.
function handle(sm, onScroll) {
  if (!sm) return null;
  return {
    dispose() { sm.dispose(); },
    scroll(p) { if (!reduced) sm.setUniforms(onScroll(p)); },
  };
}

/** Hero fallback: dark heliotrope mesh, used only while hero-heliotrope.json is missing. */
export function meshBackground(el, colors) {
  const sm = mount(el, meshGradientFragmentShader, {
    u_colors: colors.map(rgba),
    u_colorsCount: colors.length,
    u_distortion: 0.8,
    u_swirl: 0.15,
    u_grainMixer: 0.05,
    u_grainOverlay: 0.06,
    ...sizing({ u_scale: 1.1 }),
  }, 0.14);
  return handle(sm, (p) => ({ u_offsetY: p * 0.18 }));
}

/** Dials: slow silk folds, the light being "turned" across the frame. */
export async function silkWarp(el, colors) {
  const tex = await noise();
  const sm = mount(el, warpFragmentShader, {
    u_colors: colors.map(rgba),
    u_colorsCount: colors.length,
    u_proportion: 0.42,
    u_softness: 1,
    u_distortion: 0.22,
    u_swirl: 0.7,
    u_swirlIterations: 8,
    u_shape: WarpPatterns.stripes,
    u_shapeScale: 0.12,
    u_noiseTexture: tex,
    ...sizing({ u_scale: 1.4, u_rotation: -18 }),
  }, 0.16);
  return handle(sm, (p) => ({ u_rotation: -18 + p * 14, u_offsetY: p * 0.12 }));
}

/** Depth: stacked contour bands, near to far. */
export function contourDepth(el, colors) {
  const sm = mount(el, simplexNoiseFragmentShader, {
    u_colors: colors.map(rgba),
    u_colorsCount: colors.length,
    u_stepsPerColor: 3,
    u_softness: 0.12,
    ...sizing({ u_scale: 0.65 }),
  }, 0.18);
  return handle(sm, (p) => ({ u_scale: 0.65 + p * 0.08, u_offsetY: p * 0.1 }));
}

/** Light desk: soft studio panels sweeping like softboxes. */
export function studioPanels(el, colors) {
  const sm = mount(el, colorPanelsFragmentShader, {
    u_colorBack: rgba('#00000000'),
    u_colors: colors.map(rgba),
    u_colorsCount: colors.length,
    u_density: 2.6,
    u_angle1: 0.2,
    u_angle2: 0.2,
    u_length: 1.1,
    u_edges: false,
    u_blur: 0.25,
    u_fadeIn: 1,
    u_fadeOut: 0.35,
    u_gradient: 0.4,
    ...sizing({ u_scale: 0.9 }),
  }, 0.35);
  return handle(sm, (p) => ({ u_angle1: 0.2 + p * 0.25, u_angle2: 0.2 - p * 0.25 }));
}

/** Voice: a slow, grainy blob behind the mic. */
export async function voiceHaze(el, colors) {
  const tex = await noise();
  const sm = mount(el, grainGradientFragmentShader, {
    u_colorBack: rgba('#00000000'),
    u_colors: colors.map(rgba),
    u_colorsCount: colors.length,
    u_softness: 1,
    u_intensity: 0.32,
    u_noise: 0.22,
    u_shape: GrainGradientShapes.blob,
    u_noiseTexture: tex,
    ...sizing({ u_scale: 0.9 }),
  }, 0.45);
  return handle(sm, (p) => ({ u_scale: 0.9 - p * 0.12 }));
}

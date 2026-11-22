# Heliocam landing v5: text-free, Unicorn light, one camera and its models

The user's verdict on v4: "looks super vibe coded", no top bar, "a better Gemini thing", "proper
Unicorn Studio shaders", "it needs to be text-free. Rely on the user to look at the visuals." This
file overrides DESIGN_V4.md wherever they differ. Palette and type tokens stay the same.

## Lead

**Gemini is the light inside the camera.** The Gemini sparkle (a four-point star with concave sides,
blue → violet with a warm white core) is a physical light source. Every section is lit by it, and
each model is its own colour of that light, so the story reads without words:

| Who | Colour of its light | What you see it do |
|---|---|---|
| LiDAR + Depth Pro 2 (on device) | frost white `#EEF3FF` | points land on the scene, distances appear |
| `gemini-4-hydrogen` (the agent loop) | Gemini blue `#4C8DFF` | the camera's dials roll by themselves |
| `gemini-decision-1` (every second) | cyan `#6FE3FF` | the viewfinder edge pulses toward a move |
| `gemini-3.8-flash-tts` (the voice) | sun `#FFC37A` | a waveform says "That's it. Take it." |
| `gemini-4-neon` (edits, looks) | violet `#9A7CF6` | faders glide, a shader writes itself |

## Text rules (hard)

- No paragraphs, ledes, step lists or explanations. No sentence except the one tagline and the
  one spoken quote.
- Allowed text: the wordmark "Heliocam", the tagline "Gemini inside the camera.", model ids in
  Google Sans Code chips, tool calls and values as small chips (`set_camera iso 200`, `move ←`),
  distances (`2.4 m`), and section labels of at most 3 words.
- No top bar, no nav, no badges row.

## Blending (hard)

- Every Unicorn scene and section fades to ink `#05060B` at its top and bottom edges. No hard
  section edges, no boxed cards with borders, no panels. Light carries from one section into the next.
- Matte and diffuse, never glossy. Never white or washed out. No mauve or purple fields; violet is
  only Neon's light.

## Page beats

0. **Hero**: a camera iris opens to reveal the Gemini sparkle shining inside. "Heliocam" and
   "Gemini inside the camera." (Unicorn scene `v5-hero`)
1. **LiDAR**: the real scene as a point cloud with distances. Label "LiDAR · on device".
2. **Live loop** (pinned, one phone): hydrogen turns the dials → Decision pulses the edge → the
   voice says "That's it." The phone stays put while the light changes colour per model.
   (Unicorn scene `v5-model`, a variable picks the model's light)
3. **The shot**: Depth Pro 2 depth, then 3D.
4. **Neon**: Edit for Me faders, and Looks writing a shader.
5. **The real app**: nine real screens, with model chips only.
6. **Footer**: dawn over a horizon, three real phones backlit, the wordmark. (Unicorn scene `v5-footer`)

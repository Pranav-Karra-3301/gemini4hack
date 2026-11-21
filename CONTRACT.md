# Lighting coach MVP: contract

Upload a photo. A local Python server returns a depth map (Depth Pro 2 S), three coaching
regions (Gemini 4 Argon via OpenRouter) and lighting/composition scores with confidence
(Decision-1-style). A three.js page shows the photo as points: flat first; on click it pushes
out along Z from black. Clicking a region note dims everything outside its box.

## Layout

```
.env                 OPENROUTER_API_KEY=...   (never commit, never send to the browser)
server/              uv project, Python 3.12, FastAPI on http://127.0.0.1:8787
  app.py             routes (owned by lead; do not restructure)
  depth.py           Depth Pro 2 S       -> infer_depth(), warmup()
  regions.py         Gemini 4 Argon      -> find_regions()
  decide.py          decision scoring    -> score_photo()
  checks/            standalone check scripts, one per module
web/                 Vite + three.js on http://localhost:5320, proxies /api -> 127.0.0.1:8787
  public/samples/    8 sample JPEGs (1536x2048, from the wayback project)
out/                 scratch output for checks (gitignored)
```

The browser normalizes every upload before sending it: EXIF-rotated, long side <= 1536 px,
re-encoded as JPEG. The same normalized JPEG is used for display and sent to all three
endpoints, so depth, boxes and pixels line up.

## Endpoints (all POST, multipart/form-data, single field `image`)

### `/api/depth`
200 `application/octet-stream`: Float32 little-endian, row-major, top-left origin, depth in
meters, `W x H` with the long side <= 512 and the same aspect ratio as the input.
Headers (all exposed): `X-Depth-Width`, `X-Depth-Height`, `X-Depth-Min`, `X-Depth-Max`,
`X-Depth-P02`, `X-Depth-P98` (2nd/98th percentile, use these for normalization),
`X-Focal-Px`, `X-Infer-Ms`, `X-Device`.

### `/api/regions`
```json
{
  "regions": [
    {"id": "r1", "box": {"x": 0.12, "y": 0.30, "w": 0.25, "h": 0.40},
     "tag": "focus", "note": "One short line of coaching."}
  ],
  "model": "google/gemini-4-argon",
  "ms": 2300
}
```
Exactly 3 regions. `box` is normalized 0..1 of the image, origin top-left. `tag` is `"remove"`
(distracting, crop or clean it) or `"focus"` (the subject or light worth building around).
The photo is treated as already taken: every `note` is an edit (crop, tone, color, subject or
background light, depth blur, vignette), never "move", "wait" or "reshoot". Core runs Depth Pro on
the same bytes first (up to `REGIONS_DEPTH_WAIT_S`, 4 s) and puts a short depth summary in the
prompt; if depth fails or is late, regions still answer without it.

### `/api/score`
```json
{
  "provider": "emulated:<openrouter-model-id>",
  "scores": {
    "lighting":    {"score": 3.6, "scale": [1, 5], "confidence": 0.81,
                    "distribution": {"1": 0.01, "2": 0.05, "3": 0.30, "4": 0.55, "5": 0.09},
                    "label": "Soft window light, slightly underexposed"},
    "composition": {"score": 4.1, "scale": [1, 5], "confidence": 0.74,
                    "distribution": {"1": 0.0, "2": 0.02, "3": 0.15, "4": 0.52, "5": 0.31},
                    "label": "Strong leading line, subject a little centered"}
  },
  "ms": 1800
}
```
`score` is the expected value of `distribution`. `confidence` is in 0..1 (definition documented
in `decide.py`). `label` is a short human summary (may be empty).

### `/api/masks`
Multipart fields: `image` (the same normalized JPEG) and `regions` (JSON string: the `regions`
array from `/api/regions`, or that whole response object). Call it after `/api/regions` returns.
```json
{
  "masks": {
    "r1": {"png": "data:image/png;base64,...", "width": 1024, "height": 768,
           "area": 0.083, "source": "sam2.1+depth"}
  },
  "model": "<segmenter id>",
  "ms": 640
}
```
One entry per region id. Each `png` is a single-channel 8-bit mask over the WHOLE image
(not just the box), origin top-left, same aspect as the image, long side <= 1024; 255 = the
object, 0 = everything else, soft edges allowed. `area` is the mask's fraction of the image.
`source` says how it was made (e.g. `sam2.1+depth`, or `box+depth` fallback). The UI lights the
points inside the mask and drops everything else to near-black.

### `/api/splat` (3D page)
Multipart `image` (the normalized JPEG). 200 `application/octet-stream`: a SHARP `.spz` splat of
the photo (Apple SHARP via the MLX port in the wayback project, ~7 s, cached by content hash).
Headers (exposed): `X-Splat-Width`, `X-Splat-Height` (the image SHARP saw), `X-Splat-Focal-Px`
(its focal length in those pixels), `X-Splat-Ms`, `X-Splat-Cache` (`hit`|`miss`). Splats are in
the capture camera's frame, same convention as the wayback project's `.spz` files. The sample
photos already have splats at `/splats/<name>.spz` (served statically).

### `/api/reframe` (3D page)
Multipart `image`, optional `regions` (JSON string, as for `/api/masks`). Suggests one small
camera move that would improve the shot, sized from the scene's metric depth:
```json
{"move": {"x_m": -0.3, "y_m": 0.0, "z_m": 0.2, "yaw_deg": 6, "pitch_deg": 0},
 "note": "Raise the phone slightly, tilt down: show the tunnel",
 "shot": "selfie", "keep": ["man in grey tee, centre", "man in black tee, left"],
 "scene": "cypress tree tunnel and its vanishing point", "model": "gemini-4-hydrogen", "ms": 5300}
```
The model first decides what kind of shot it is, who must stay fully in frame (`keep`: every
person in the shot), and what background makes the place (`scene`). Then it picks the move that
keeps them all in and shows more of the scene. For a selfie the move is an arm move (raise,
extend, tilt), not walking away from the group.
Camera frame: x right, y down, z forward (meters); positive yaw turns right, positive pitch
tilts up. Moves are clamped to |x|,|y| ≤ 0.6 m, |z| ≤ 0.8 m, |yaw|,|pitch| ≤ 15°.

### Errors
Any endpoint: non-2xx with JSON `{"error": "<message>"}`. The UI shows the error in that
panel and keeps the rest working.

# Depth Pro 2 S on the iPhone (Core ML)

The app runs Apple's own Core ML build of Depth Pro 2 S (`depthpro2-s_w4.mlpackage` from
[apple/DepthPro2-coreml](https://huggingface.co/apple/DepthPro2-coreml)), so there's no conversion
step. The package is 51 MB, gitignored, and lives at
`apple/CoachCam/CoachCam/Resources/Models/DepthPro2S.mlpackage`. Xcode compiles it to
`DepthPro2S.mlmodelc` in the app. Without it the app builds and falls back to LiDAR depth.

## Get the model

```bash
uv run tools/depthpro2_coreml/fetch.py
cd apple/CoachCam && xcodegen generate
```

## The model

- Input `frame`: float16 `(1, 3, 480, 854)`, RGB in [0, 1]. Normalization is inside the model.
  The package has the functions `res_854x480` (used), `res_640x360`, `res_896x512`,
  `res_1138x640` and `res_1280x720`. All of them are 16:9 landscape.
- Output `inverse_depth`: float16 `(1, 480, 854)`, normalized by focal length. Metres =
  `f_px / (854 * inverse_depth)`, with `f_px` the focal length in pixels of the frame.
- It's stateful (a 4-frame video window). `DepthPro2.swift` makes a fresh state for each photo.
- `DepthPro2.swift` fits the photo into the frame and replicate-pads the rest (right and bottom).
  `f_px` comes from the photo's 35mm-equivalent EXIF focal length, or 24 mm (the iPhone main
  camera) when the photo has none. The focal/FOV head (`depthpro2-fov_512x896.mlpackage`, 91 MB)
  isn't bundled.

## Parity with PyTorch

`parity.py` compares the Core ML model with the PyTorch model (`depth_pro_2`)
on one photo:

```bash
uv run --python 3.12 --with torch --with numpy --with pillow \
  --with "depth-pro-2 @ git+https://github.com/apple-aiml-research/ml-depth-pro-2" \
  python -I tools/depthpro2_coreml/parity.py torch PHOTO.jpg /tmp/dp2-ref.npz
python -I tools/depthpro2_coreml/parity.py coreml /tmp/dp2-ref.npz \
  apple/CoachCam/CoachCam/Resources/Models/DepthPro2S.mlpackage   # needs coremltools
```

Measured on 2026-11-21 on `web/public/samples`:

| Photo | Fitted size | Inverse depth corr | Median metric depth error |
|---|---|---:|---:|
| img-2178 (16:9) | 853x480 | 1.0000 | 0.2% |
| img-1016 (4:3 landscape) | 640x480 | 0.9968 | 6% |
| img-1216 (3:4 portrait) | 360x480 | 0.9957 | 15% |

The model itself matches PyTorch. The gap on 4:3 and 3:4 photos comes from the padding: the
network sees a wider frame than PyTorch does, which shifts the metric scale. To close it, export a
package at the photo's aspect with Apple's exporter, for example
`uv run --extra coreml python -m demo.export stream -m depthpro2-s -w 4 -s 480x640` in
[ml-depth-pro-2](https://github.com/apple-aiml-research/ml-depth-pro-2) (`-s` is HxW), and change
`frameWidth`/`frameHeight` and `functionName` in `DepthPro2.swift` to match.

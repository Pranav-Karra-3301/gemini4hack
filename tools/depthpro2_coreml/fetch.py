"""Fetch Apple's Core ML Depth Pro 2 S into the iPhone app (no conversion needed).

  server/.venv/bin/python -I tools/depthpro2_coreml/fetch.py

Downloads `depthpro2-s_w4.mlpackage` from apple/DepthPro2-coreml (pinned revision) into a fresh
temp dir and copies it to apple/CoachCam/CoachCam/Resources/Models/DepthPro2S.mlpackage, which
is gitignored. Xcode compiles it to DepthPro2S.mlmodelc in the app bundle.
"""

from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

from huggingface_hub import snapshot_download

REPO = "apple/DepthPro2-coreml"
REVISION = "4e607a682f993bbf95035054fc78ba9ffc81faf2"
PACKAGE = "depthpro2-s_w4.mlpackage"
DEST = (Path(__file__).resolve().parents[2]
        / "apple/CoachCam/CoachCam/Resources/Models/DepthPro2S.mlpackage")


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        snapshot_download(REPO, revision=REVISION, allow_patterns=[f"{PACKAGE}/*"], local_dir=tmp)
        src = Path(tmp) / PACKAGE
        if not (src / "Manifest.json").is_file():
            raise SystemExit(f"{REPO}@{REVISION} has no {PACKAGE}")
        if DEST.exists():
            shutil.rmtree(DEST)
        DEST.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, DEST)
    size = sum(p.stat().st_size for p in DEST.rglob("*") if p.is_file())
    print(f"{DEST} ({size / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()

"""Run the planning geometry model against a pinned upstream source, outside the repo.

No dependencies are installed. No app windows or repository build are touched.
Requires macOS's existing Swift toolchain and network access for the pinned file.
"""
from pathlib import Path
import hashlib
import subprocess
import tempfile
import urllib.request

COMMIT = "18c058aa856afd3b09fc98a567dc492d2b981b85"
URL = f"https://raw.githubusercontent.com/rxhanson/Rectangle/{COMMIT}/Rectangle/MultiWindow/GridTiling.swift"

source = urllib.request.urlopen(URL, timeout=25).read()
prototype = Path(__file__).with_name("auto-layout-model.swift").read_bytes()
with tempfile.TemporaryDirectory(prefix="octopus-auto-layout-proof-") as directory:
    root = Path(directory)
    harness = root / "main.swift"
    harness.write_bytes(source + b"\n" + prototype)
    print(f"Rectangle source commit: {COMMIT}", flush=True)
    print(f"Rectangle source SHA256: {hashlib.sha256(source).hexdigest()}", flush=True)
    subprocess.run(["swift", "-module-cache-path", str(root / "module-cache"), str(harness)], check=True)

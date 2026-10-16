"""Package the supplied, unchanged artwork at macOS icon resolutions."""
import pathlib
import struct
import subprocess

root = pathlib.Path(__file__).resolve().parent
iconset = root / "Mufus.iconset"
iconset.mkdir(exist_ok=True)
chunks = []
for size, code, filename in [
    (16, "icp4", "icon_16x16.png"),
    (32, "icp5", "icon_32x32.png"),
    (64, "icp6", "icon_32x32@2x.png"),
    (128, "ic07", "icon_128x128.png"),
    (256, "ic08", "icon_256x256.png"),
    (512, "ic09", "icon_512x512.png"),
    (1024, "ic10", "icon_512x512@2x.png"),
]:
    target = iconset / filename
    subprocess.run(["/usr/bin/sips", "-z", str(size), str(size), str(root / "Mufus.png"), "--out", str(target)], check=True, capture_output=True)
    png = target.read_bytes()
    chunks.append(code.encode("ascii") + struct.pack(">I", len(png) + 8) + png)
payload = b"".join(chunks)
(root / "Mufus.icns").write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
print("Packaged supplied USB artwork as Mufus.icns")

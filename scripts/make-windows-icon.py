"""Package the existing macOS icon PNG sizes as a Windows ICO, without changing artwork."""
from pathlib import Path
import struct

root = Path(__file__).resolve().parent.parent
iconset = root / "build/icon/AppIcon.iconset"
images = [(size, (iconset / ("icon_32x32@2x.png" if size == 64 else f"icon_{size}x{size}.png")).read_bytes()) for size in (16, 32, 64, 128, 256)]
offset = 6 + 16 * len(images)
entries = []
for size, data in images:
    entries.append(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
    offset += len(data)
destination = root / "windows/Reprise.Windows/Assets/Reprise.ico"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_bytes(struct.pack("<HHH", 0, 1, len(images)) + b"".join(entries) + b"".join(data for _, data in images))
print(destination)

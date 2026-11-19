#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
app="$stage/Screen Translate.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
python3 - AppleTranslate.png "$app/Contents/Resources/AppIcon.icns" <<'ICON'
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

chunks = []
with tempfile.TemporaryDirectory() as directory:
    for kind, size in ((b"icp4", 16), (b"icp5", 32), (b"ic07", 128),
                       (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024)):
        output = Path(directory) / "image.png"
        subprocess.run(["sips", "-z", str(size), str(size), sys.argv[1], "--out", output],
                       check=True, stdout=subprocess.DEVNULL)
        png = output.read_bytes()
        chunks.append(struct.pack(">4sI", kind, len(png) + 8) + png)
data = b"".join(chunks)
Path(sys.argv[2]).write_bytes(struct.pack(">4sI", b"icns", len(data) + 8) + data)
ICON
for arch in arm64 x86_64; do
    xcrun swiftc -O -module-cache-path "$stage/cache" -sdk "$sdk" -target "$arch-apple-macosx15.0" main.swift -o "$stage/$arch"
done
xcrun lipo -create "$stage/arm64" "$stage/x86_64" -output "$app/Contents/MacOS/ScreenTranslate"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
mkdir -p dist
ditto "$app" "dist/Screen Translate.app"
ditto -c -k --keepParent "$app" "dist/Screen Translate.zip"

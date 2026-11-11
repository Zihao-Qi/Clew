# App icon

`bunny-source.png` is the icon the user chose (2026-11-11): a minimal bunny doodle on a soft
peach tile. It came as a flat 1254 × 1254 image with its corners and shadow baked onto white.

`make-app-icon.swift` turns it into a macOS icon: it crops the tile's inside, redraws it as an
824 pt rounded tile on a transparent 1024 canvas (the macOS icon grid) with a soft shadow.
The sizes in `App/Clew/Assets.xcassets/AppIcon.appiconset` are made from that 1024 image:

```sh
swift design/app-icon/make-app-icon.swift design/app-icon/bunny-source.png /tmp/icon-1024.png
for s in 16 32 64 128 256 512 1024; do
  sips -z $s $s /tmp/icon-1024.png --out App/Clew/Assets.xcassets/AppIcon.appiconset/icon_$s.png
done
```

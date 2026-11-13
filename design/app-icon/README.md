# App icon

`daruma-source.png` is the current app icon (2026-11-12): a warm folk-craft Daruma doll on a
washi-cream background with both eyes filled. (`bunny-source.png` was the initial v1 icon.)

`make-app-icon.swift` turns the square source art into a macOS icon: it draws it as an
824 pt rounded tile on a transparent 1024 canvas (the macOS icon grid) with a soft shadow.
The sizes in `App/Clew/Assets.xcassets/AppIcon.appiconset` are made from that 1024 image:

```sh
swift design/app-icon/make-app-icon.swift design/app-icon/daruma-source.png App/Clew/Assets.xcassets/AppIcon.appiconset/icon_1024.png
for s in 16 32 64 128 256 512; do
  sips -z $s $s App/Clew/Assets.xcassets/AppIcon.appiconset/icon_1024.png --out App/Clew/Assets.xcassets/AppIcon.appiconset/icon_$s.png
done
```

For pre-framed source images with baked corners/margins (like `bunny-source.png`), pass
`--crop x,y,w,h` (e.g. `--crop 52,53,1148,1148`).

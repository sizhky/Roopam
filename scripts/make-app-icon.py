"""Builds the app and helper icons from one square artwork image.

Usage: python3 scripts/make-app-icon.py <source.png>

The source is either
  - a rounded-square icon on a plain opaque background, or full-bleed square art: it is cropped
    (full-bleed art is used whole), masked to the
    macOS icon shape, and placed as the 824 px body of the 1024 px grid with a soft shadow, or
  - an object with transparent corners (for example a background-removed folder): it is
    cleaned up and centered in the 824 px area with a soft shadow; the background stays transparent.
The script writes:

    Roopam/Resources/AppIcon-master-1024.png
    Roopam/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png
    Roopam/Resources/AppIcon.icns
    Roopam/Resources/HelperIcon.icns   (app icon with a "?" badge)

>>> superellipse_mask(8, 2).size
(8, 8)
>>> [clean_alpha(v) for v in (10, 136, 252)]
[0, 128, 255]
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Roopam/Resources"
CANVAS, BODY = 1024, 824
SIZES = [16, 32, 128, 256, 512]


def superellipse_mask(size, scale=4, exponent=5.0):
    """Antialiased mask of the macOS continuous-corner icon shape: |x|^n + |y|^n <= 1."""
    big = size * scale
    mask = Image.new("L", (big, big), 0)
    pixels = mask.load()
    half = big / 2
    for y in range(big):
        dy = abs((y + 0.5 - half) / half) ** exponent
        if dy > 1:
            continue
        # Row extent solved directly: |x| <= (1 - dy)^(1/n).
        extent = int((1 - dy) ** (1 / exponent) * half)
        for x in range(int(half - extent), int(half + extent)):
            pixels[x, y] = 255
    return mask.resize((size, size), Image.LANCZOS)


def crop_to_body(image):
    """Crops the rounded square off its plain background; full-bleed art (corners differ) is used whole."""
    rgb = image.convert("RGB")
    w, h = rgb.size
    corners = [rgb.getpixel(p) for p in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1))]
    if max(abs(c[i] - corners[0][i]) for c in corners for i in range(3)) > 24:
        return rgb
    background = Image.new("RGB", rgb.size, rgb.getpixel((0, 0)))
    diff = ImageChops.difference(rgb, background).convert("L").point(lambda v: 255 if v > 24 else 0)
    box = diff.getbbox()
    if box is None:
        raise SystemExit("error: no artwork found on the background")
    return rgb.crop(box)


def clean_alpha(value):
    """Drops faint background-removal halo (< 32) and makes near-opaque pixels (>= 240) opaque."""
    return 0 if value < 32 else 255 if value >= 240 else round((value - 32) * 255 / 208)


def object_on_grid(image):
    """Centers a transparent-background object in the 824 px icon area, keeping the background transparent."""
    rgba = image.convert("RGBA")
    rgba.putalpha(rgba.getchannel("A").point(clean_alpha))
    rgba = rgba.crop(rgba.getchannel("A").getbbox())
    scale = BODY / max(rgba.size)
    rgba = rgba.resize((round(rgba.width * scale), round(rgba.height * scale)), Image.LANCZOS)
    origin = ((CANVAS - rgba.width) // 2, (CANVAS - rgba.height) // 2)
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 80), (origin[0], origin[1] + 12), rgba.getchannel("A"))
    canvas = shadow.filter(ImageFilter.GaussianBlur(14))
    canvas.alpha_composite(rgba, origin)
    return canvas


def icon_from(image):
    """Picks the source mode from its corners: transparent corners mean an object."""
    if image.mode in ("RGBA", "LA", "P") and image.convert("RGBA").getpixel((0, 0))[3] < 32:
        return object_on_grid(image)
    return place_on_grid(crop_to_body(image))


def place_on_grid(body):
    body = body.resize((BODY, BODY), Image.LANCZOS).convert("RGBA")
    mask = superellipse_mask(BODY)
    body.putalpha(mask)
    offset = (CANVAS - BODY) // 2
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (offset, offset + 12), mask)
    canvas = shadow.filter(ImageFilter.GaussianBlur(14))
    canvas.alpha_composite(body, (offset, offset))
    return canvas


def with_badge(icon):
    """Adds the grey "?" diamond the helper bundle uses to look distinct from the app."""
    badge_size = 300
    badge = Image.new("RGBA", (badge_size, badge_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(badge)
    draw.rounded_rectangle((40, 40, badge_size - 40, badge_size - 40), radius=36,
                           fill=(110, 110, 115, 235), outline=(70, 70, 75, 255), width=6)
    badge = badge.rotate(45, resample=Image.BICUBIC)
    draw = ImageDraw.Draw(badge)
    font = ImageFont.truetype("/System/Library/Fonts/SFNSRounded.ttf", 150)
    draw.text((badge_size / 2, badge_size / 2), "?", font=font, fill=(235, 235, 240, 255), anchor="mm")
    out = icon.copy()
    out.alpha_composite(badge, (CANVAS - 100 - badge_size + 40, CANVAS - 100 - badge_size + 40))
    return out


def write_icns(icon, destination):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "icon.iconset"
        iconset.mkdir()
        for size in SIZES:
            icon.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
            icon.resize((size * 2, size * 2), Image.LANCZOS).save(iconset / f"icon_{size}x{size}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(destination)], check=True)


def main(source):
    icon = icon_from(Image.open(source))
    icon.save(RESOURCES / "AppIcon-master-1024.png")
    appiconset = RESOURCES / "Assets.xcassets/AppIcon.appiconset"
    for size in SIZES:
        icon.resize((size, size), Image.LANCZOS).save(appiconset / f"icon_{size}x{size}.png")
        icon.resize((size * 2, size * 2), Image.LANCZOS).save(appiconset / f"icon_{size}x{size}@2x.png")
    write_icns(icon, RESOURCES / "AppIcon.icns")
    write_icns(with_badge(icon), RESOURCES / "HelperIcon.icns")
    print(f"Wrote app and helper icons from {source}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])

"""Draws the app icon: a car seen from above inside green viewfinder corners
(the app's vacant colour), on a dark blue gradient. Needs Pillow.

    python3 ios/tools/icon.py ios/SpotWatch/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

Drawn at 4x and scaled down for smooth edges; saved as RGB, since iOS icons
can't have transparency (the home screen rounds the corners itself).
"""
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
S = 4                                   # supersampling factor
TOP, BOTTOM = (28, 43, 68), (10, 18, 32)
GREEN = (64, 186, 79)                   # the overlay's vacant colour
BODY = (238, 241, 245)
GLASS = (36, 52, 77)
HEAD = (255, 211, 107)
TAIL = (242, 85, 74)


def px(v):
    return round(v * S)


def box(x0, y0, x1, y1):
    return [px(x0), px(y0), px(x1), px(y1)]


def poly(points):
    return [(px(x), px(y)) for x, y in points]


def main(out):
    n = SIZE * S
    img = Image.new("RGB", (n, n))
    d = ImageDraw.Draw(img)
    for y in range(n):
        t = y / (n - 1)
        d.line([(0, y), (n, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))

    # Viewfinder corners, with round ends.
    m, arm, w = 180, 150, 44
    for cx, sx in ((m, 1), (SIZE - m, -1)):
        for cy, sy in ((m, 1), (SIZE - m, -1)):
            for ex, ey in ((cx + sx * arm, cy), (cx, cy + sy * arm)):
                d.line(poly([(cx, cy), (ex, ey)]), fill=GREEN, width=px(w))
                d.ellipse(box(ex - w / 2, ey - w / 2, ex + w / 2, ey + w / 2), fill=GREEN)
            d.ellipse(box(cx - w / 2, cy - w / 2, cx + w / 2, cy + w / 2), fill=GREEN)

    # Soft shadow under the car.
    shadow = Image.new("L", (n, n), 0)
    ImageDraw.Draw(shadow).rounded_rectangle(box(384, 290, 640, 792), radius=px(100), fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(px(22)))
    img.paste(Image.new("RGB", (n, n), (4, 8, 14)), (0, 0), shadow)
    d = ImageDraw.Draw(img)

    # The car, nose up: mirrors, body, lights, windscreen and rear window.
    d.rounded_rectangle(box(358, 430, 404, 468), radius=px(14), fill=BODY)
    d.rounded_rectangle(box(620, 430, 666, 468), radius=px(14), fill=BODY)
    d.rounded_rectangle(box(392, 262, 632, 762), radius=px(96), fill=BODY)
    d.rounded_rectangle(box(418, 276, 470, 298), radius=px(10), fill=HEAD)
    d.rounded_rectangle(box(554, 276, 606, 298), radius=px(10), fill=HEAD)
    d.rounded_rectangle(box(420, 734, 470, 750), radius=px(8), fill=TAIL)
    d.rounded_rectangle(box(554, 734, 604, 750), radius=px(8), fill=TAIL)
    d.polygon(poly([(416, 398), (608, 398), (586, 476), (438, 476)]), fill=GLASS)
    d.polygon(poly([(440, 604), (584, 604), (600, 664), (424, 664)]), fill=GLASS)

    img.resize((SIZE, SIZE), Image.LANCZOS).save(out)


if __name__ == "__main__":
    main(sys.argv[1])

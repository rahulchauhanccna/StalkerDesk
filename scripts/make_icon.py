import math
import os
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Rounded-square background with a diagonal gradient.
margin = 34
radius = 220
gradient = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
gdraw = ImageDraw.Draw(gradient)
top = (10, 24, 39)
bottom = (22, 78, 96)
for y in range(SIZE):
    t = y / max(SIZE - 1, 1)
    color = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3)) + (255,)
    gdraw.line([(0, y), (SIZE, y)], fill=color)

mask = Image.new("L", (SIZE, SIZE), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    [margin, margin, SIZE - margin, SIZE - margin], radius=radius, fill=255
)
img.alpha_composite(Image.composite(gradient, Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0)), mask))

# Glow ring.
glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
gdraw = ImageDraw.Draw(glow)
cx = cy = SIZE // 2
for r, alpha, width in [(330, 40, 16), (300, 80, 50)]:
    gdraw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(64, 210, 224, alpha), width=width)
glow = glow.filter(ImageFilter.GaussianBlur(18))
img.alpha_composite(Image.composite(glow, Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0)), mask))

draw = ImageDraw.Draw(img)
# Crisp ring.
draw.ellipse([cx - 300, cy - 300, cx + 300, cy + 300], outline=(88, 228, 240, 255), width=10)

# Play triangle.
points = [(cx - 105, cy - 150), (cx - 105, cy + 150), (cx + 176, cy)]
triangle = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
tdraw = ImageDraw.Draw(triangle)
tdraw.polygon(points, fill=(255, 255, 255, 255))
shadow = triangle.filter(ImageFilter.GaussianBlur(22))
img.alpha_composite(shadow)
img.alpha_composite(triangle)

# Live dot.
dot_x, dot_y, dot_r = cx + 210, cy - 205, 34
dot_glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
dglow = ImageDraw.Draw(dot_glow)
dglow.ellipse([dot_x - dot_r*2, dot_y - dot_r*2, dot_x + dot_r*2, dot_y + dot_r*2], fill=(255, 62, 72, 70))
dot_glow = dot_glow.filter(ImageFilter.GaussianBlur(22))
img.alpha_composite(dot_glow)
draw.ellipse([dot_x - dot_r, dot_y - dot_r, dot_x + dot_r, dot_y + dot_r], fill=(255, 62, 72, 255))

out = os.path.join("Resources", "AppIcon.iconset")
os.makedirs(out, exist_ok=True)
for size in [16, 32, 64, 128, 256, 512, 1024]:
    resized = img.resize((size, size), Image.LANCZOS)
    resized.save(os.path.join(out, f"icon_{size}x{size}.png"))
    if size <= 512:
        resized2 = img.resize((size * 2, size * 2), Image.LANCZOS)
        resized2.save(os.path.join(out, f"icon_{size}x{size}@2x.png"))
print("iconset written")

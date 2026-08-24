from PIL import Image
import sys
import os



SIZES = {
    "thumbnail": (150, 150),
    "medium": (800, 800),
    "large": (1600, 1600)
}

def resize_image(input_path, output_dir="."):
    img = Image.open(input_path)
    base_name = os.path.splitext(os.path.basename(input_path))[0]

    for label, size in SIZES.items():
        resized = img.copy()
        # Preserve the aspect ratio
        resized.thumbnail(size)
        out_path = os.path.join(output_dir, f"{base_name}_{label}.jpg")
        resized.convert("RGB").save(out_path, "JPEG")
        print(f"Wrote {out_path} ({resized.size[0]}x{resized.size[1]})")



if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python resize.py <image_path>")
        sys.exit(1)

    resize_image(sys.argv[1])
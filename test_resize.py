import os
from PIL import Image
from resize import resize_image, SIZES


def make_test_image(path, size):
    Image.new("RGB", size, color="red").save(path, "JPEG")


def test_resize_shrinks_large_image(tmp_path):
    input_path = tmp_path / "large_source.jpg"
    make_test_image(input_path, (2000, 2000))

    resize_image(str(input_path), output_dir=str(tmp_path))

    for label, (max_w, max_h) in SIZES.items():
        output_path = tmp_path / f"large_source_{label}.jpg"
        assert output_path.exists(), f"missing output for {label}"

        with Image.open(output_path) as img:
            assert img.width <= max_w
            assert img.height <= max_h


def test_resize_never_upscales_small_image(tmp_path):
    input_path = tmp_path / "small_source.jpg"
    make_test_image(input_path, (50, 50))

    resize_image(str(input_path), output_dir=str(tmp_path))

    for label in SIZES:
        output_path = tmp_path / f"small_source_{label}.jpg"
        assert output_path.exists(), f"missing output for {label}"

        with Image.open(output_path) as img:
            assert img.size == (50, 50)


def test_resize_preserves_aspect_ratio(tmp_path):
    input_path = tmp_path / "wide_source.jpg"
    make_test_image(input_path, (2000, 1000))

    resize_image(str(input_path), output_dir=str(tmp_path))

    with Image.open(tmp_path / "wide_source_thumbnail.jpg") as img:
        assert img.width <= 150
        assert img.height <= 150
        # 2:1 aspect ratio should be preserved within the thumbnail box
        assert abs((img.width / img.height) - 2.0) < 0.05

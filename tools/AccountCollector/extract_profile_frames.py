"""Build a private local frame index from an already extracted Unity bundle/table.

No network access. Inputs and generated game artwork must remain outside Git.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import sys


def extract(bundle, table, output):
    import UnityPy
    from PIL import Image
    sprites = {}
    for obj in UnityPy.load(str(bundle)).objects:
        if obj.type.name == "Sprite":
            sprite = obj.read()
            name = sprite.m_Name.casefold()
            if name in sprites:
                raise ValueError("duplicate_frame_sprite")
            sprites[name] = sprite

    def canvas(name):
        sprite = sprites[name.casefold()]
        data = sprite.m_RD
        if sprite.m_SpriteAtlas:
            atlas = sprite.m_SpriteAtlas.deref_parse_as_object()
            data = next(value for key, value in atlas.m_RenderDataMap if key == sprite.m_RenderDataKey)
        # Unity packs away transparent margins. Restore them before overlaying
        # base and sub-resource, otherwise ornaments shift or stretch.
        image = sprite.image.convert("RGBA")
        scale = data.downscaleMultiplier or 1
        width, height = round(sprite.m_Rect.width / scale), round(sprite.m_Rect.height / scale)
        x, y = round(data.textureRectOffset.x / scale), round(data.textureRectOffset.y / scale)
        result = Image.new("RGBA", (width, height))
        result.alpha_composite(image, (x, height - y - image.height))
        return result

    output.mkdir(parents=True, exist_ok=True)
    frames = {}
    for row in json.loads(table.read_text(encoding="utf-8-sig")):
        composed = canvas(row["ResourceId"])
        if row.get("SubResourceId"):
            sub = canvas(row["SubResourceId"])
            if sub.size != composed.size:
                raise ValueError("frame_canvas_size_mismatch")
            composed.alpha_composite(sub)
        stream = io.BytesIO()
        composed.save(stream, format="PNG")
        content = stream.getvalue()
        digest = hashlib.sha256(content).hexdigest()
        (output / (digest + ".png")).write_bytes(content)
        frames[str(row["Id"])] = digest
    # An explicit zero means no equipped frame, distinct from missing metadata.
    stream = io.BytesIO()
    Image.new("RGBA", (128, 128)).save(stream, format="PNG")
    digest = hashlib.sha256(stream.getvalue()).hexdigest()
    (output / (digest + ".png")).write_bytes(stream.getvalue())
    frames.setdefault("0", digest)
    manifest = {"contract": "local-profile-frames/v1", "frames": frames}
    (output / "index.private.json").write_text(json.dumps(manifest), encoding="utf-8")
    print(json.dumps({"mappedFrames": len(frames), "uniqueImages": len(set(frames.values()))}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--table", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--unitypy-root", type=Path)
    args = parser.parse_args()
    if args.unitypy_root:
        sys.path.insert(0, str(args.unitypy_root.resolve()))
    extract(args.bundle, args.table, args.output)

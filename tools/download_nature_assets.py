#!/usr/bin/env python3
"""
Downloads optimized 1K glTF nature assets (trees, stones, plants) from Poly Haven
into models/nature/ for RealBallPutting background scenery.
"""

import os
import sys
import json
import urllib.request
import concurrent.futures

ASSETS = {
    # Trees
    "pine_sapling_small": {"category": "trees", "name": "Pine Tree (Small)"},
    "fir_sapling": {"category": "trees", "name": "Fir Tree (Sapling)"},
    "searsia_lucida": {"category": "trees", "name": "Deciduous Bush Tree"},
    "tree_stump_01": {"category": "trees", "name": "Mossy Tree Stump"},
    
    # Stones
    "stone_01": {"category": "stones", "name": "Smooth Stone"},
    "rock_07": {"category": "stones", "name": "Natural Boulder"},
    "sand_rocks_small_01": {"category": "stones", "name": "Ground Pebbles / Stones"},
    
    # Plants & Bushes
    "shrub_01": {"category": "plants", "name": "Broadleaf Shrub"},
    "shrub_02": {"category": "plants", "name": "Flowering Bush"},
    "periwinkle_plant": {"category": "plants", "name": "Periwinkle Ground Plant"},
    "grass_medium_01": {"category": "plants", "name": "Grass Tuft Clump"},
}

def download_file(url, dest_path):
    if os.path.exists(dest_path) and os.path.getsize(dest_path) > 0:
        return
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (PolyHavenDownloader)"})
    with urllib.request.urlopen(req) as resp, open(dest_path, "wb") as f:
        f.write(resp.read())

def fetch_asset(asset_id, meta):
    category = meta["category"]
    display_name = meta["name"]
    out_dir = os.path.join("models", "nature", category, asset_id)
    os.makedirs(out_dir, exist_ok=True)
    
    api_url = f"https://api.polyhaven.com/files/{asset_id}"
    req = urllib.request.Request(api_url, headers={"User-Agent": "Mozilla/5.0 (PolyHavenDownloader)"})
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
    except Exception as e:
        print(f"❌ Failed to fetch info for {asset_id}: {e}", file=sys.stderr)
        return False

    gltf_info = data.get("gltf", {}).get("1k", {}).get("gltf", {})
    if not gltf_info:
        print(f"⚠️ No 1k gltf available for {asset_id}", file=sys.stderr)
        return False

    main_url = gltf_info["url"]
    main_filename = os.path.basename(main_url)
    main_dest = os.path.join(out_dir, main_filename)
    
    print(f"📦 [{category.upper()}] Downloading {display_name} ({asset_id})...")
    download_file(main_url, main_dest)

    for rel_path, inc_meta in gltf_info.get("include", {}).items():
        inc_url = inc_meta["url"]
        inc_dest = os.path.join(out_dir, rel_path)
        download_file(inc_url, inc_dest)

    print(f"✅ [{category.upper()}] Finished {display_name} -> {out_dir}")
    return True

def main():
    print(f"🌿 Downloading {len(ASSETS)} Poly Haven assets to models/nature/...")
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        futures = {executor.submit(fetch_asset, aid, meta): aid for aid, meta in ASSETS.items()}
        for fut in concurrent.futures.as_completed(futures):
            aid = futures[fut]
            try:
                fut.result()
            except Exception as e:
                print(f"❌ Error downloading {aid}: {e}")

    print("\n🎉 All Poly Haven nature models downloaded successfully!")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Turns the plain PNGs in this folder into app-icon sets.

Sonora lets you choose its Home Screen icon in Settings > App Icon. Each
choice has to be an "icon set" inside the asset catalogue, which is one
folder per icon. To keep the repository simple, the icons are stored here
as flat files instead:

    <id>-light.png   the icon                (1024 x 1024, no transparency)
    <id>-dark.png    its dark-mode version   (optional)

The build runs this script first. It creates
Sonora/Resources/Assets.xcassets/AppIcon-<id>.appiconset for every
<id>-light.png found here. The icon the app ships with ("AppIcon") is not
touched.
"""

import glob
import json
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(HERE, "..", "Sonora", "Resources", "Assets.xcassets")
SUFFIX = "-light.png"


def main():
    made = []
    for light in sorted(glob.glob(os.path.join(HERE, "*" + SUFFIX))):
        icon_id = os.path.basename(light)[: -len(SUFFIX)]
        folder = os.path.join(CATALOG, "AppIcon-" + icon_id + ".appiconset")
        os.makedirs(folder, exist_ok=True)

        images = [{
            "filename": "light.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }]
        shutil.copyfile(light, os.path.join(folder, "light.png"))

        dark = light[: -len(SUFFIX)] + "-dark.png"
        if os.path.exists(dark):
            shutil.copyfile(dark, os.path.join(folder, "dark.png"))
            images.append({
                "appearances": [{"appearance": "luminosity", "value": "dark"}],
                "filename": "dark.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            })

        with open(os.path.join(folder, "Contents.json"), "w") as out:
            json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, out, indent=2)
        made.append(icon_id)

    print("Prepared %d alternate app icons: %s" % (len(made), ", ".join(made)))
    if not made:
        raise SystemExit("No icons found in " + HERE)


if __name__ == "__main__":
    main()

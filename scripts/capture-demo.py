"""Capture real PNG responses from an opted-in viewer. Open File > Open demo first.

This does not open files, create patients, save bookmarks, or enable MCP.
Use only the authorized bundled demo when preparing public media.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tests"))
from MCPAcceptance import Client


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--demo-is-open", action="store_true", required=True,
                        help="Confirm that File > Open demo is the active study")
    args = parser.parse_args()
    try:
        info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        parser.error(f"Cannot read app Info.plist: {error}")
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    if (version, build) != ("1.14.0", "21"):
        parser.error(f"Expected INV Viewer 1.14.0 (21); got {version} ({build})")
    args.out.mkdir(parents=True, exist_ok=False)
    client = Client(args.app / "Contents/MacOS/INVViewer")
    records = []

    def call(name, **arguments):
        started = time.monotonic()
        result = client.tool(name, **arguments)
        record = {"tool": name, "arguments": arguments,
                  "elapsed_ms": round((time.monotonic() - started) * 1000),
                  "isError": bool(result.get("isError"))}
        if "structuredContent" in result:
            record["result"] = result["structuredContent"]
        if record["isError"]:
            record["content"] = result.get("content", [])
        records.append(record)
        return result

    def action(name, **arguments):
        result = call(name, **arguments)
        if result.get("isError"):
            raise RuntimeError(result)
        return result["structuredContent"]

    def capture(name, **arguments):
        deadline = time.monotonic() + 15
        while True:
            result = call("get_image", **arguments)
            if not result.get("isError"):
                break
            if time.monotonic() > deadline:
                raise RuntimeError(result)
            time.sleep(0.1)
        item = next(x for x in result["content"] if x["type"] == "image")
        png = base64.b64decode(item["data"], validate=True)
        assert png.startswith(b"\x89PNG\r\n\x1a\n")
        path = args.out / (name + ".png")
        path.write_bytes(png)
        records[-1].update(file=path.name, sha256=hashlib.sha256(png).hexdigest())
        print("Captured", path.name, flush=True)

    try:
        client.send("initialize", {"protocolVersion": "2024-11-05",
                    "capabilities": {}, "clientInfo": {"name": "inv-demo-capture", "version": "1.14.0"}})
        client.send("notifications/initialized", notification=True)
        state = action("get_state")
        assert state["loaded"] and state["dimensions"] == [400, 400, 300]
        action("set_view", view="panorama")
        action("navigate", jaw="upper")
        action("navigate", position_mm=54)
        capture("panorama")
        action("set_view", view="cross_section")
        for position in range(44, 65, 2):
            action("navigate", position_mm=position)
            capture(f"section-{position:03}")
        action("set_view", view="mpr")
        for plane, slice_number in (("axial", 171), ("coronal", 180), ("sagittal", 200)):
            action("navigate", mpr_plane=plane, slice=slice_number)
            capture("mpr-" + plane, mpr_plane=plane)
        for slice_number in (160, 180, 200):
            action("navigate", mpr_plane="coronal", slice=slice_number)
            capture(f"mcp-coronal-{slice_number}", mpr_plane="coronal")
        action("set_view", view="volume_3d")
        action("configure_volume", reset=True, zoom=1.7)
        for frame in range(61):
            if frame:
                action("configure_volume", yaw_deg=3)
            capture(f"volume-{frame:03}")
        action("configure_volume", reset=True, zoom=1.7)
        for frame in range(11):
            action("configure_volume", clip_axis="axial", clip_position=1 - frame / 20)
            capture(f"clip-{frame:03}")
        action("configure_volume", reset=True)
        action("set_view", view="panorama")
        action("navigate", position_mm=54)
    finally:
        client.close()
        (args.out / "transcript.json").write_text(json.dumps({
            "app_version": version, "build": build,
            "source": "bundled authorized clinical demo; confirmed by operator",
            "presentation": "Edited sequence of actual MCP responses; not a real-time screen recording",
            "records": records}, indent=2) + "\n")


if __name__ == "__main__":
    main()

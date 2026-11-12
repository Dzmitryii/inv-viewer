"""Exercise the bundled stdio server against a live, opted-in demo window."""

import argparse
import base64
import hashlib
import json
import math
from pathlib import Path
import select
import struct
import subprocess
import time
import uuid


class Client:
    def __init__(self, executable):
        self.process = subprocess.Popen([str(executable), "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.request_id = 0

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()

    def send(self, method, params=None, notification=False):
        self.request_id += 1
        request = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            request["params"] = params
        if not notification:
            request["id"] = self.request_id
        self.process.stdin.write(json.dumps(request).encode() + b"\n")
        self.process.stdin.flush()
        if notification:
            return None
        assert select.select([self.process.stdout], [], [], 10)[0], f"{method} timed out"
        response = json.loads(self.process.stdout.readline())
        assert response["id"] == self.request_id and "error" not in response, response
        return response["result"]

    def tool(self, tool_name, **arguments):
        return self.send("tools/call", {"name": tool_name, "arguments": arguments})

    def state(self, tool_name="get_state", **arguments):
        response = self.tool(tool_name, **arguments)
        assert not response.get("isError"), response
        return response["structuredContent"]

    def image(self, **arguments):
        # Panorama and Metal preparation can finish after set_view returns.
        deadline = time.monotonic() + 5
        while True:
            response = self.tool("get_image", **arguments)
            if not response.get("isError"):
                break
            assert time.monotonic() < deadline, response
            time.sleep(0.05)
        image = next(item for item in response["content"] if item["type"] == "image")
        png = base64.b64decode(image["data"], validate=True)
        assert image["mimeType"] == "image/png" and png[:8] == b"\x89PNG\r\n\x1a\n"
        return response["structuredContent"], struct.unpack(">II", png[16:24]), hashlib.sha256(png).digest()


def verify(client, result_path):
    assert client.state()["dimensions"] == [400, 400, 300], "Open the bundled demo before running the test."
    assert client.tool("get_state", unexpected=True)["isError"]
    assert client.tool("navigate", steps=2, slice=3)["isError"]
    for plane, size in (("axial", (400, 400)), ("coronal", (400, 300)), ("sagittal", (400, 300))):
        assert client.state("set_view", view=plane)["view"] == plane
        assert client.state("navigate", slice=101)["slice"] == 101
        state, dimensions, _ = client.image()
        assert state["image_plane"] == plane and state["image_slice"] == 101 and dimensions == size
    assert client.tool("get_image", mpr_plane="axial")["isError"]
    print("PASS · strict arguments, three slice views, PNG coordinates and dimensions", flush=True)

    assert client.state("set_view", view="panorama")["view"] == "panorama"
    for jaw in ("lower", "upper"):
        assert client.state("navigate", jaw=jaw)["jaw"] == jaw
        assert abs(client.state("navigate", position_mm=54)["position_mm"] - 54) < 0.21
        _, _, panorama = client.image()
        assert client.state("set_view", view="cross_section")["view"] == "cross_section"
        frame, dimensions, section = client.image()
        assert panorama != section and dimensions[1] == 300
        measured = client.state("measure", image_id=frame["image_id"], first=[0.45, 0.45], second=[0.55, 0.45])
        assert measured["distance_mm"] > 0
        assert client.state("set_view", view="panorama")["view"] == "panorama"
    print("PASS · both arches, panoramas, detailed cross-sections and cross-section ruler", flush=True)

    assert client.state("set_view", view="mpr")["view"] == "mpr"
    assert client.state("navigate", slice=180, mpr_plane="coronal")["active_plane"] == "coronal"
    for plane in ("axial", "sagittal", "coronal"):
        frame, _, _ = client.image(mpr_plane=plane)
        assert frame["image_plane"] == plane and frame["active_plane"] == "coronal"
    assert frame["image_slice"] == 180
    points = {"first": [0.25, 0.5], "second": [0.5, 0.5]}
    assert math.isclose(client.state("measure", image_id=frame["image_id"], **points)["distance_mm"], 20)
    name = "Acceptance " + uuid.uuid4().hex[:8]
    bookmark = client.state("bookmark", action="save", name=name, note="Synthetic verification")["bookmark"]
    assert bookmark["has_note"] and math.isclose(bookmark["distance_mm"], 20)
    assert client.state("bookmark", action="save", name=name, note="Synthetic verification")["bookmark"] == bookmark
    client.state("navigate", steps=1, mpr_plane="coronal")
    assert client.tool("measure", image_id=frame["image_id"], **points)["isError"]
    listed = client.state("bookmark", action="list")["bookmarks"]
    assert sum(item["id"] == bookmark["id"] for item in listed) == 1
    opened = client.state("bookmark", action="open", id=bookmark["id"])
    assert opened["view"] == "mpr" and math.isclose(opened["distance_mm"], 20)
    assert client.image(mpr_plane="coronal")[0]["image_slice"] == 180
    print("PASS · MPR targeting, 20 mm ruler, stale-image rejection and idempotent saved bookmark", flush=True)

    assert client.state("set_view", view="volume_3d")["view"] == "volume_3d"
    original, dimensions, frontal = client.image()
    assert original["render_ready"] and max(dimensions) == 768
    settings = client.state("configure_volume", yaw_deg=45, pitch_deg=10, preset="soft_tissue",
                            clip_axis="sagittal", clip_position=0.4, reverse_clip=True,
                            zoom=1.2, opacity=0.8, density=0.1)
    assert settings["rotation_xyzw"] != original["rotation_xyzw"] and settings["clip_axis"] == "sagittal"
    assert settings["preset"] == "soft_tissue" and settings["reverse_clip"]
    assert client.tool("configure_volume", zoom=8, yaw_deg=10)["isError"]
    assert client.state()["rotation_xyzw"] == settings["rotation_xyzw"]
    assert client.image()[2] != frontal
    assert client.state("configure_volume", reset=True)["rotation_xyzw"] == original["rotation_xyzw"]
    assert client.state("set_view", view="panorama")["view"] == "panorama"
    print("PASS · 3D window, rotation, controls, PNG readback, atomic error and reset", flush=True)
    result_path.write_text(bookmark["id"] + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("bookmark_id", type=Path)
    parser.add_argument("--reopen", action="store_true")
    parser.add_argument("--disconnected", action="store_true")
    args = parser.parse_args()
    client = Client(args.app / "Contents/MacOS/INVViewer")
    try:
        initialized = client.send("initialize", {"protocolVersion": "2025-11-25",
                                                  "clientInfo": {"name": "acceptance", "version": "1"},
                                                  "capabilities": {}})
        assert initialized["protocolVersion"] == "2025-11-25"
        client.send("notifications/initialized", notification=True)
        assert client.send("ping") == {}
        assert {tool["name"] for tool in client.send("tools/list")["tools"]} == {
            "get_state", "set_view", "navigate", "get_image", "configure_volume", "measure", "bookmark"
        }
        if args.disconnected:
            assert client.tool("get_state")["isError"]
            print("PASS · MCP client returns a tool error with the viewer closed or listener disabled")
        elif args.reopen:
            opened = client.state("bookmark", action="open", id=args.bookmark_id.read_text().strip())
            assert opened["view"] == "mpr" and math.isclose(opened["distance_mm"], 20)
            assert client.image(mpr_plane="coronal")[0]["image_slice"] == 180
            print("PASS · the same bookmark and ruler reopen after restarting the app")
        else:
            verify(client, args.bookmark_id)
    finally:
        client.close()


if __name__ == "__main__":
    main()

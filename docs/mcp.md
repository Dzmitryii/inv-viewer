# Local MCP

The optional bridge is disabled on a new installation. Choose **Tools → Local MCP** in the viewer to enable it. It listens in the application's container over a same-user Unix socket. Each copy and build has its own endpoint. Configure the client to launch the executable from the same app bundle that you open on screen. There is no TCP listener.

Run the MCP client on the same Mac. Its server command is the app executable below, with `--mcp` as the argument. Configuration formats differ between clients; this example uses a TOML `mcp_servers` table:

```toml
[mcp_servers.inv-viewer]
command = "/absolute/path/to/INV Viewer.app/Contents/MacOS/INVViewer"
args = ["--mcp"]
```

- `get_state` reads the open study's view, geometry and rendering state.
- `set_view` selects `axial`, `coronal`, `sagittal`, `mpr`, `panorama`, `cross_section` or `volume_3d`.
- `navigate` moves through slices and along the dental arch. In MPR, include `mpr_plane` with `slice` or `steps` to choose the linked plane.
- `configure_volume` adjusts the open 3D view, including rotation, preset, zoom, density, opacity and clipping. Set `reset` to `true` for the default settings.
- `get_image` returns a PNG and its view metadata. In MPR, an optional `mpr_plane` chooses the image, and `image_plane` identifies the plane in the response. Retry after rendering if the image is pending.
- `measure` uses the `image_id` of the latest MPR or detailed cross-section PNG and two points as `[x, y]` fractions from the top-left. The points should come from the user. The viewer rejects outdated geometry and places the ruler on the same plane as the returned image.
- `bookmark` accepts `action: "list"`, `action: "save"` with a `name` and optional `note`, or `action: "open"` with an `id`. Saving records the current 2D view and its ruler in the existing local study store. A repeated save with the same view, name and note returns the existing bookmark.

The viewer returns the open image to the client only on request. A client can handle the returned data under its own privacy policy. Turn the listener off from the same menu when finished. Restart a client that cached the tool list to discover newly added tools.

## Repeat the demonstration

1. Build/open 1.14.0 and choose **File → Open demo**. Use this authorized demo, not a private patient scan, for public captures.
2. Enable **Tools → Local MCP**. Configure the executable path above to the **same** app bundle. After upgrading or moving the app, restart/reconnect the MCP client so it launches that executable again.
3. Ask your client: “Switch to MPR, show coronal slice 180, and return the image.” The expected sequence is:

```json
[
  {"name":"set_view","arguments":{"view":"mpr"}},
  {"name":"navigate","arguments":{"mpr_plane":"coronal","slice":180}},
  {"name":"get_image","arguments":{"mpr_plane":"coronal"}}
]
```

The array lists the calls in order. Send each object as the `params` of a separate MCP `tools/call` request, waiting for its response before sending the next. Do not send the whole array as one request. Slices are **one-based**. In this demo, the last reply is a 400×300 PNG with `image_plane: "coronal"` and `image_slice: 180`. Natural-language clients may choose a different sequence; these calls reproduce the example.

For 3D, call `set_view` with `{"view":"volume_3d"}`, then `configure_volume` with `{"reset":true,"zoom":1.7}`. A `yaw_deg: 3` rotates **relative to the current camera**, not to an absolute heading. Call `get_image` after each change. For clipping, use `{"clip_axis":"axial","clip_position":0.5}`. The response comes from the viewer’s renderer.

[Watch the edited MCP capture](assets/mcp-demo.mp4) · [Recorded requests, states and PNG hashes](assets/mcp-transcript.json).

To make a fresh sequence yourself, with the demo already open and MCP enabled:

```sh
python3 scripts/capture-demo.py \
  --app "/absolute/path/to/INV Viewer.app" \
  --out ".build/demo-capture" \
  --demo-is-open
```

The script checks the supplied bundle is version 1.14.0, build 21 before creating output or starting MCP. The destination must not already exist. The confirmation flag means you checked **Demo · clinical scan** on screen; matching dimensions alone cannot establish a study's identity. The script uses Python's standard library and the repository's stdio test client. It changes viewing state and saves local PNGs and a transcript. It does not create patients, measurements or bookmarks, and does not enable MCP. Capture private studies only under your own applicable permissions, outside public source trees.

## Troubleshooting

- **No viewer / disconnected:** open the app and a study, check Local MCP, and verify the client executable path matches the running bundle. Do not point at an older backup copy.
- **Tools missing after an update:** reconnect/restart the client. The server advertises seven tools in this version.
- **Image pending:** wait for rendering and retry `get_image`. This can happen immediately after a mode switch.
- **Measurement rejected:** request a new MPR or detailed cross-section image; use that latest `image_id` and user-selected endpoints. Do not reuse coordinates from an older view.
- **Command process exits before initialize:** run the client normally on macOS; a nested sandbox can prevent launching an already sandboxed app executable. Do not change the application's entitlements to work around it.

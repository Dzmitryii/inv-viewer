# Local MCP

The optional bridge is disabled on a new installation. Choose **Tools → Local MCP** in the viewer to enable it. It listens in the application's container over a same-user Unix socket. Each copy and build has its own endpoint. Configure the client to launch the executable from the same app bundle that you open on screen. There is no TCP listener.

## Connect Codex on this Mac

First [build and open the app](install.md), choose **File → Open demo**, and enable **Tools → Local MCP**. Keep the viewer open. Use the included demo for the first connection check.

### Add the server

If you have the Codex CLI, run these commands **from the `inv-viewer` repository folder** after building:

```sh
(
  app_path="$(pwd -P)/.build/INV Viewer.app"
  if [ ! -x "$app_path/Contents/MacOS/INVViewer" ]; then
    printf 'App not found at %s. Run this from the repository folder after building.\n' "$app_path" >&2
    exit 1
  fi
  codex mcp add inv-viewer -- "$app_path/Contents/MacOS/INVViewer" --mcp &&
    codex mcp get inv-viewer
)
```

`codex mcp get` should show that executable path and the `--mcp` argument. If you see `App not found`, finish the build first and check that you are in the folder containing `build.sh`. The commands stop without changing the server configuration when the app is missing. If the app is elsewhere, set `app_path` to its full path instead. Always open that same copy in Finder.

If you use the desktop app without the CLI, edit **`~/.codex/config.toml`** in a plain-text editor. In Finder, choose **Go → Go to Folder…** and enter `~/.codex/` to find the file. Create `config.toml` as plain text if it does not exist. Add the table below, replacing the example path with the full path to your app. If an `inv-viewer` table already exists, update it instead of adding a second one. Keep your other settings.

```toml
[mcp_servers.inv-viewer]
command = "/absolute/path/to/INV Viewer.app/Contents/MacOS/INVViewer"
args = ["--mcp"]
```

To obtain the path, select `INV Viewer.app` in Finder and press **Option-Command-C** to copy its pathname. Append `/Contents/MacOS/INVViewer` inside the quotes. The `~` in the configuration-file location means your home folder; the `command` itself must contain an absolute path.

### Reconnect and check

1. Restart Codex after saving the configuration, then start a new chat. Keep INV Viewer open with Local MCP enabled. In the Codex CLI, `/mcp` shows connected servers and their tools.
2. Ask: **“Use inv-viewer to read the current viewer state.”** The client should call `get_state` and return the open view and study dimensions. This checks the connection without requesting a scan image.
3. With **Open demo** selected in INV Viewer, ask: **“Switch to MPR, show coronal slice 180, and return the image.”** Expect a coronal PNG and slice 180 in the response. The calls are shown below.

The server advertises **seven tools**. `codex mcp get` checks the saved configuration; a successful `get_state` checks the live connection. See [OpenAI's MCP configuration guide](https://developers.openai.com/codex/mcp/) for the client's configuration options.

## Other MCP clients

Use a local **stdio** server on the same Mac. Set the command to the app executable's absolute path and arguments to `["--mcp"]`. The TOML above is for Codex; other clients have their own configuration format. This server has no HTTP URL, API key or OAuth login.

## Available tools

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

[Watch the edited MCP capture](https://dzmitryii.github.io/inv-viewer/#mcp) · [Recorded requests, states and PNG hashes](assets/mcp-transcript.json).

To make a fresh sequence yourself, with the demo already open and MCP enabled:

```sh
python3 scripts/capture-demo.py \
  --app "/absolute/path/to/INV Viewer.app" \
  --out ".build/demo-capture" \
  --demo-is-open
```

The script checks the supplied bundle is version 1.14.0, build 21 before creating output or starting MCP. The destination must not already exist. The confirmation flag means you checked **Demo · clinical scan** on screen; matching dimensions alone cannot establish a study's identity. The script uses Python's standard library and the repository's stdio test client. It changes viewing state and saves local PNGs and a transcript. It does not create patients, measurements or bookmarks, and does not enable MCP. Capture private studies only under your own applicable permissions, outside public source trees.

## Troubleshooting

- **`codex: command not found`:** use the desktop configuration-file method above, or install the CLI using OpenAI’s instructions.
- **No viewer / disconnected:** open the app and a study, check Local MCP, and verify the client executable path matches the running bundle. Do not point at an older backup copy.
- **Tools missing after an update:** reconnect/restart the client. The server advertises seven tools in this version.
- **Image pending:** wait for rendering and retry `get_image`. This can happen immediately after a mode switch.
- **Measurement rejected:** request a new MPR or detailed cross-section image; use that latest `image_id` and user-selected endpoints. Do not reuse coordinates from an older view.
- **Command process exits before initialize:** run the client normally on macOS; a nested sandbox can prevent launching an already sandboxed app executable. Do not change the application's entitlements to work around it.

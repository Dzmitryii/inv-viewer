# Demo recordings

The videos show INV Viewer 1.14.0 (build 21), recorded on an Apple Silicon Mac running macOS 27.2.1 on 2026-11-12.

## Source material

The product video uses screenshots of the app's welcome screen, panorama, cross-section, MPR and 3D window, followed by frames returned through MCP. All views show the bundled clinical demo, used under [these media terms](assets/NOTICE.md).

The MCP video pairs tool calls with their returned images. The [transcript](assets/mcp-transcript.json) contains the requests, response metadata, measured request durations and SHA-256 hashes of the source PNGs. Its sequence includes coronal slices 160, 180 and 200, 61 rotation frames and 11 clipping frames.

Both videos are edited for length. Titles and layout were added during editing; playback time does not represent request latency. Intermediate setup calls are in the transcript.

## Repeat the capture

Follow [MCP setup](mcp.md), open **File → Open demo**, then run:

```sh
python3 scripts/capture-demo.py \
  --app "/absolute/path/to/INV Viewer.app" \
  --out ".build/demo-capture" \
  --demo-is-open
```

The script checks the app version, saves PNG replies and writes a transcript. Confirm the demo is open before running it. Image hashes identify the recorded run; they can differ with the GPU, viewport or runtime. The raw PNGs are not included in the public transcript.

## Editing and export

Composition used Pillow 11.3.0 and FFmpeg 8.1.2 with local system fonts. These are media-production tools, not app dependencies. Each MP4 is 24 seconds, 1920×1080, H.264 at 12 fps, with no audio. The README GIF is 800 pixels wide; use the MP4 for full-size text.

The English and Russian preview pages use local videos and screenshots. Videos do not autoplay. See [installation](install.md) for the local preview command.

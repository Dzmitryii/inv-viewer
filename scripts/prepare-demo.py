#!/usr/bin/env python3
"""Build or audit the public INV example. Accepts only the supported raw INV layout."""
import argparse
import hashlib
import math
import re
import struct
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

VOLUME_ATTRIBUTES = {
    "Source": "Appended", "Offset": "0", "ScalarType": "UInt16", "NumComp": "1",
}
NUMERIC_ATTRIBUTES = {"Dimensions": 3, "Spacing": 3, "Origin": 3, "CoordinateSystem": 7, "WindowLevel": 2}
OPENING = b"<AppendedData encoding='raw'>"
CLOSING = b"</AppendedData></INVFile>"
IMAGE_MARKERS = {bytes.fromhex(code) for code in ("ff51", "ff52", "ff5c", "ff5d", "ff64", "ff90", "ff93")}
# This encoder comment describes the codestream producer and contains no scan metadata.
ENCODER_COMMENT = re.compile(rb"(?:Created by OpenJPEG version |Creator: JasPer Version )[0-9]+(?:\.[0-9]+){1,3}")

def require(condition, message):
    if not condition:
        raise ValueError(message)

def numbers(value, count):
    parts = value.replace("\\", " ").split()
    require(len(parts) == count and all(re.fullmatch(r"[+\-0-9.eE]+", part) for part in parts),
            "Unexpected numeric metadata")
    require(all(math.isfinite(float(part)) for part in parts), "Nonfinite numeric metadata")
    return " ".join(parts)

def inspect_codestream(block):
    require(block[:2] == b"\xff\x4f" and block[-2:] == b"\xff\xd9", "Invalid JPEG 2000 framing")
    pos = 2
    tile_end = None
    while pos < len(block) - 2:
        marker = block[pos:pos + 2]
        require(marker in IMAGE_MARKERS, "Unrecognized JPEG 2000 marker")
        if marker == b"\xff\x93":
            require(tile_end is not None and pos + 2 <= tile_end <= len(block) - 2, "Invalid tile span")
            pos, tile_end = tile_end, None
            continue
        require(pos + 4 <= len(block) - 2, "Truncated JPEG 2000 segment")
        size = int.from_bytes(block[pos + 2:pos + 4], "big")
        end = pos + 2 + size
        require(2 <= size and end <= (tile_end or len(block) - 2), "Invalid JPEG 2000 segment length")
        if marker == b"\xff\x64":
            comment = block[pos + 6:end]
            require(ENCODER_COMMENT.fullmatch(comment) is not None, "Unrecognized JPEG 2000 comment")
        if marker == b"\xff\x90":
            require(tile_end is None and size == 10, "Invalid tile header")
            tile_end = pos + int.from_bytes(block[pos + 6:pos + 10], "big")
            require(end < tile_end <= len(block) - 2, "Unbounded JPEG 2000 tile")
        pos = end
    require(pos == len(block) - 2 and tile_end is None, "Unclosed JPEG 2000 tile")

def public_copy(source):
    require(0 < len(source) <= 256 * 1024 * 1024, "Unsupported file size")
    header = source[:256 * 1024]
    start = header.find(b"<AppendedData")
    require(start > 0 and b"<!" not in header[:start], "Unsupported header")
    payload_start = header.index(b">", start) + 1
    root = ET.fromstring(header[:payload_start] + CLOSING)
    require(root.tag == "INVFile" and root.attrib == {"version": "2.0", "byteOrder": "LittleEndian"},
            "Unsupported INV header")
    require(root.find("AppendedData").attrib == {"encoding": "raw"}, "Unsupported INV encoding")
    volume = root.find("Volume").attrib
    require(all(volume.get(key) == value for key, value in VOLUME_ATTRIBUTES.items()), "Unsupported voxel layout")
    public_root = ET.Element("INVFile", {"version": "2.0", "byteOrder": "LittleEndian"})
    case = ET.SubElement(public_root, "CaseInfo")
    image = ET.SubElement(case, "ImageInfo")
    orientation = root.find("CaseInfo/ImageInfo/ImageOrientationPatient").attrib["Value"]
    ET.SubElement(image, "ImageOrientationPatient", {"Value": numbers(orientation, 6)})
    fields = VOLUME_ATTRIBUTES | {key: numbers(volume[key], count) for key, count in NUMERIC_ATTRIBUTES.items()}
    ET.SubElement(public_root, "Volume", fields)
    ET.indent(public_root, space="  ")
    public_xml = ET.tostring(public_root, encoding="utf-8").removesuffix(b"</INVFile>")

    magic, count, per, last = struct.unpack_from("<IIII", source, payload_start)
    require(magic == 0x5f202020 and 1 <= count <= 2048 and 1 <= last <= per <= 64,
            "Invalid INV block table")
    pos = payload_start + 16 + 4 * count
    require(pos <= len(source), "Truncated INV block table")
    for size in struct.unpack_from(f"<{count}I", source, payload_start + 16):
        require(0 < size <= len(source) - pos, "Invalid INV block size")
        inspect_codestream(source[pos:pos + size])
        pos += size
    require(b"".join(source[pos:].split()) == CLOSING and len(source) - pos <= 256, "Unexpected trailing data")
    payload = source[payload_start:pos]
    return public_xml + OPENING + payload + CLOSING, hashlib.sha256(payload).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument("--output", type=Path)
    operation.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    try:
        with args.source.open("rb") as file:
            source = file.read(256 * 1024 * 1024 + 1)
        public, payload_hash = public_copy(source)
        if args.verify:
            require(source == public, "The demo contains non-allowlisted metadata or formatting")
        else:
            with args.output.open("xb") as file:
                file.write(public)
    except (AttributeError, ET.ParseError, KeyError, OSError, ValueError, struct.error) as error:
        # Report only the error class for OS/XML failures that may include private text or paths.
        message = str(error) if type(error) is ValueError else type(error).__name__
        sys.exit(f"Demo preparation failed: {message}")
    print(f"PASS · geometry-only header, audited JPEG 2000; payload SHA-256 {payload_hash}")

if __name__ == "__main__":
    main()

"""Validation helpers for the packed COOD image format."""

import struct
from pathlib import Path

MAGIC = 0x434F4F44
HEADER_BYTES = 512
BLOCK_BYTES = 512
DDR3_WINDOW_BYTES = 0x0800_0000


def load_image(path):
    image = Path(path).read_bytes()
    if len(image) < HEADER_BYTES:
        raise ValueError("image is shorter than its 512-byte header")

    fields = struct.unpack_from("<9I", image)
    (magic, blocks, destination, payload_bytes, records, rows, cols,
     labels, checksum) = fields
    if magic != MAGIC:
        raise ValueError(f"bad image magic 0x{magic:08x}")
    if blocks == 0 or payload_bytes == 0:
        raise ValueError("image has no payload")
    if records == 0 or rows == 0 or cols == 0 or labels == 0:
        raise ValueError("image metadata contains zero dimensions or records")
    if destination % 4:
        raise ValueError("destination offset must be 4-byte aligned")
    padded_payload_bytes = (payload_bytes + 3) & ~3
    if destination + padded_payload_bytes > DDR3_WINDOW_BYTES:
        raise ValueError("payload exceeds the DDR3 window")
    expected_payload_bytes = records * (rows * cols + labels)
    if payload_bytes != expected_payload_bytes:
        raise ValueError(
            "payload length does not match the declared MNIST dimensions")
    if blocks != (payload_bytes + BLOCK_BYTES - 1) // BLOCK_BYTES:
        raise ValueError("header block count does not match payload length")
    if len(image) != HEADER_BYTES + blocks * BLOCK_BYTES:
        raise ValueError("file size does not match header block count")

    payload = image[HEADER_BYTES:HEADER_BYTES + payload_bytes]
    if sum(payload) & 0xFFFFFFFF != checksum:
        raise ValueError("payload checksum does not match header")
    return image[:HEADER_BYTES], payload, records, rows, cols

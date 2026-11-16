#!/usr/bin/env python3
"""Send a packed COODA MNIST image to the FPGA over USB bulk OUT."""

import argparse
import sys

from mnist_image import load_image

DEFAULT_VID = 0xCAFE
DEFAULT_PID = 0x4001
DEFAULT_ENDPOINT = 0x01


def write_all(device, endpoint, data, timeout_ms):
    offset = 0
    while offset < len(data):
        written = device.write(endpoint, data[offset:], timeout=timeout_ms)
        if written is None or written <= 0:
            raise TimeoutError("USB bulk write made no progress")
        offset += written
    return offset


def parse_usb_id(value):
    try:
        result = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            "USB IDs must be integers such as 0xCAFE") from exc
    if not 0 <= result <= 0xFFFF:
        raise argparse.ArgumentTypeError("USB IDs must fit in 16 bits")
    return result


def main():
    parser = argparse.ArgumentParser(
        description="Transfer a packed MNIST image over USB bulk OUT.")
    parser.add_argument("--vid", type=parse_usb_id, default=DEFAULT_VID,
                        help="USB vendor ID (default: 0xCAFE)")
    parser.add_argument("--pid", type=parse_usb_id, default=DEFAULT_PID,
                        help="USB product ID (default: 0x4001)")
    parser.add_argument("--endpoint", type=parse_usb_id,
                        default=DEFAULT_ENDPOINT,
                        help="bulk OUT endpoint address (default: 0x01)")
    parser.add_argument("--timeout-ms", type=int, default=5000,
                        help="per-write timeout in milliseconds")
    parser.add_argument("image", help="packed MNIST .img file")
    args = parser.parse_args()

    try:
        if args.timeout_ms <= 0:
            raise ValueError("timeout must be positive")
        if args.endpoint > 0x0F:
            raise ValueError("endpoint must be a bulk OUT address from 0x00 to 0x0F")
        header, payload, records, rows, cols = load_image(args.image)
        try:
            import usb.core
        except ImportError as exc:
            raise RuntimeError(
                "PyUSB is required; install it with: python3 -m pip install pyusb"
            ) from exc

        device = usb.core.find(idVendor=args.vid, idProduct=args.pid)
        if device is None:
            raise RuntimeError(
                f"USB device {args.vid:04x}:{args.pid:04x} was not found")
        device.set_configuration()

        total_bytes = len(header) + len(payload)
        print(f"Sending {records} records ({rows}x{cols}), "
              f"{total_bytes:,} image bytes over USB...")
        chunk_size = 16 * 1024
        image = header + payload
        for offset in range(0, len(image), chunk_size):
            chunk = image[offset:offset + chunk_size]
            write_all(device, args.endpoint, chunk, args.timeout_ms)
            sent = offset + len(chunk)
            print(f"\rSent {sent:,}/{total_bytes:,} bytes", end="", flush=True)
        print()
        print("USB accepted the image stream; the FPGA checks its checksum "
              "before marking the DDR3 load complete.")
    except (OSError, ValueError, TimeoutError, RuntimeError) as exc:
        sys.exit(f"error: {exc}")


if __name__ == "__main__":
    main()

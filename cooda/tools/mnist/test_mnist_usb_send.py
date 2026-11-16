import argparse
import struct
import tempfile
import unittest
from pathlib import Path

import mnist_usb_send

def build_image(payload=b"abcdefghij", destination=0):
    blocks = (len(payload) + 511) // 512
    words = [0] * 128
    words[:9] = [
        0x434F4F44, blocks, destination, len(payload), 2, 2, 2, 1,
        sum(payload) & 0xFFFFFFFF,
    ]
    padded = payload + bytes(blocks * 512 - len(payload))
    return struct.pack("<128I", *words) + padded


class FakeDevice:
    def __init__(self, max_write=3):
        self.max_write = max_write
        self.written = bytearray()

    def write(self, _endpoint, data, timeout):
        self.assert_timeout = timeout
        count = min(len(data), self.max_write)
        self.written.extend(data[:count])
        return count


class UsbWriteTests(unittest.TestCase):
    def test_load_image_validates_and_returns_unpadded_payload(self):
        image = build_image()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mnist.img"
            path.write_bytes(image)
            header, payload, records, rows, cols = \
                mnist_usb_send.load_image(path)

        self.assertEqual(len(header), 512)
        self.assertEqual(payload, b"abcdefghij")
        self.assertEqual((records, rows, cols), (2, 2, 2))

    def test_load_image_rejects_misaligned_destination(self):
        image = build_image(destination=1)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mnist.img"
            path.write_bytes(image)
            with self.assertRaisesRegex(ValueError, "4-byte aligned"):
                mnist_usb_send.load_image(path)

    def test_load_image_rejects_checksum_mismatch(self):
        image = bytearray(build_image())
        image[512] ^= 1
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mnist.img"
            path.write_bytes(image)
            with self.assertRaisesRegex(ValueError, "checksum"):
                mnist_usb_send.load_image(path)

    def test_write_all_retries_short_writes(self):
        device = FakeDevice()
        written = mnist_usb_send.write_all(device, 1, b"headerpayload", 1000)

        self.assertEqual(written, len(b"headerpayload"))
        self.assertEqual(device.written, b"headerpayload")
        self.assertEqual(device.assert_timeout, 1000)

    def test_write_all_rejects_no_progress(self):
        device = FakeDevice(max_write=0)

        with self.assertRaisesRegex(TimeoutError, "no progress"):
            mnist_usb_send.write_all(device, 1, b"data", 1000)

    def test_parse_usb_id_accepts_hexadecimal_and_rejects_overflow(self):
        self.assertEqual(mnist_usb_send.parse_usb_id("0xCAFE"), 0xCAFE)

        with self.assertRaises(argparse.ArgumentTypeError):
            mnist_usb_send.parse_usb_id("0x10000")


if __name__ == "__main__":
    unittest.main()

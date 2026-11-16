# MNIST quick start: PC to FPGA over USB

This guide sends a packed MNIST image from a PC to the Tang Primer 20K
through an external ULPI PHY. The FPGA validates the image header and
payload checksum, writes the payload to DDR3, and the HDMI viewer displays
the records.

## Requirements

- Sipeed Tang Primer 20K with its dock, programmed with the COODA
  `fpga_top` design.
- A USB3317-compatible ULPI PHY wired to the FPGA pins in
  `src/constraints/sipeed_tang_primer_20k.cst`.
- Python 3 and PyUSB on the PC. On Linux, install a libusb backend if
  one is not already available.
- MNIST IDX image and label files. Place
  `train-images-idx3-ubyte` and `train-labels-idx1-ubyte` in
  `data/mnist/`.

The ULPI clock is provided by the PHY at 60 MHz. The data bus, DIR, NXT,
STP, and active-low PHY reset use the supplied board pin mapping. A
serial-only USB adapter cannot carry this protocol; the ULPI PHY is the
required interface between the FPGA and host USB.
The ULPI clock and four data pins that were on bank 2 have been moved to
unused bank-0 pins because bank 2 is held at 1.5 V by the microSD interface.
If you wired the PHY using the earlier pin map, rewire it to match
`src/constraints/sipeed_tang_primer_20k.cst` before programming the FPGA.

The USB descriptors use local-development defaults VID `0xCAFE` and PID
`0x4001`. They are configurable with the `USB_VID` and `USB_PID`
parameters in `fpga_top`. Assign unique IDs before distributing hardware.

## 1. Program the FPGA

Open `cooda.gprj` in Gowin EDA, regenerate/build the USB device controller
IP with the ULPI interface selected, build `fpga_top`, and program the
resulting bitstream. The default board parameters select USB
(`USB_ENABLE=1`, `SD_ENABLE=0`).

After reset, wait for DDR3 calibration before sending data. The USB device
uses bulk OUT endpoint `0x01`; the host can enumerate it while the image
loader is waiting, but it accepts image bytes only when DDR3 is ready and
SW2 (E9) is high. LED0 lights when the raw SW2 input is high. If the
switch is active-low on your board, build with
`USB_READ_ACTIVE_LEVEL=0`. The loader accepts one image per reset.

## 2. Install the host dependency

From the repository root:

```sh
python3 -m pip install pyusb
```

Windows may require a libusb-compatible driver (such as WinUSB) for the
device. The USB VID/PID must match the FPGA parameters if you changed them.

## 3. Pack and upload a small test set

```sh
python3 tools/mnist/mnist_pack.py \
    --images data/mnist/train-images-idx3-ubyte \
    --labels data/mnist/train-labels-idx1-ubyte \
    --limit 12 \
    --out /tmp/mnist-12.img

python3 tools/mnist/mnist_usb_send.py /tmp/mnist-12.img
```

For custom USB IDs, pass for example `--vid 0x1234 --pid 0x5678`.
The sender validates the packed file before opening USB and transfers the
512-byte image header followed by exactly the unpadded payload.

## 4. Upload the full training set

Omit `--limit` to pack the complete 60,000-record training set:

```sh
python3 tools/mnist/mnist_pack.py \
    --images data/mnist/train-images-idx3-ubyte \
    --labels data/mnist/train-labels-idx1-ubyte \
    --out /tmp/mnist-train.img

python3 tools/mnist/mnist_usb_send.py /tmp/mnist-train.img
```

The payload is about 47.1 MB. USB bulk transfers are packetized and
back-pressured while the FPGA writes DDR3; actual transfer time depends on
the PHY, host, and DDR3 bus. Keep the FPGA powered and do not reset it
during transfer.

The sender's completion message means the host sent the image bytes to the
USB endpoint. The FPGA verifies the checksum and completes DDR3 writes
internally; this version does not return a completion/error status over
the USB IN endpoint. Physical enumeration, sustained transfer, and DDR3
contents must be verified on hardware.

## Troubleshooting

- If the device does not enumerate, verify the ULPI PHY clock, reset
  polarity, ULPI data direction/tri-state wiring, Gowin IP configuration,
  and VID/PID values.
- If sending times out, wait for DDR3 calibration and confirm endpoint
  `0x01` is configured as bulk OUT.
- If the HDMI viewer shows no dataset after the transfer, reset and retry;
  verify the DDR3 PHY and inspect `load_error`/`error_code` in the FPGA
  design.

For the microSD loader, set `USB_ENABLE=0` and `SD_ENABLE=1`. The USB and
microSD loaders share a single bus slot.

## Change the display rate

The viewer starts at one image per second. Press `btn_n2` (header pin T12)
to double the rate, or `btn_n3` (T11) to halve it. Rates step through 1,
3, 7, 15, 30, and 60 images per second.

The available regression and host-tool tests can be run with:

```sh
python3 -m unittest discover -s tools/mnist -p 'test_*.py'
./run.sh --no-gui
```

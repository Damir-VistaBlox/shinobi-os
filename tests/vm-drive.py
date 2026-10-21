#!/usr/bin/env python3
"""Drive a QEMU guest through its monitor: press keys, type text, take screenshots.

    vm-drive.py --monitor SOCKET keys [--gap SECONDS] KEY...
    vm-drive.py --monitor SOCKET type [--layout L [--variant V] [--options O]] [--gap S] [--enter] TEXT
    vm-drive.py --monitor SOCKET shot FILE.png
    vm-drive.py --monitor SOCKET quit
    vm-drive.py translate [--layout L ...] TEXT        (no guest: print the key names)

Keys are QEMU's `sendkey` names, which are names of *physical positions* on a US keyboard
(`y` is the key a US keyboard has a Y on), so they type whatever the guest's layout says
that key is. That is what makes this usable as a person with a German keyboard: `type
--layout de 'zy'` presses the keys a German keyboard has a Z and a Y on, and the guest
reads them through whatever layout it is really on. If the guest is on `us` instead (a
session that did not follow the layout chosen in the installer), the same presses read
as 'yz', which is the failure this exists to be able to see.

The translation is done with the real xkb library (tests/xkb-decode.py), so every layout
xkb knows works, for any character that can be typed without AltGr. A character that
needs AltGr, or that the layout cannot type, is an error, not a guess.

The screendump goes through the monitor's `screendump`, which writes a PPM that this
converts to a PNG with the standard library: no imaging package is needed.
"""
import argparse
import importlib.util
import os
import socket
import struct
import sys
import tempfile
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))

# The keys whose QEMU name is not the character they type on a US keyboard.
NAMES = {
    " ": "spc", "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
    "\\": "backslash", ";": "semicolon", "'": "apostrophe", ",": "comma", ".": "dot",
    "/": "slash", "`": "grave_accent", "\n": "ret", "\t": "tab",
}


def _xkb():
    spec = importlib.util.spec_from_file_location("xkb_decode", os.path.join(HERE, "xkb-decode.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def translate(text, layout="us", variant="", options=""):
    """The QEMU key names that type `text` on a keyboard with this layout."""
    xkb = _xkb()
    lib = xkb.load()
    target = xkb.Keymap(lib, layout, variant, options)
    us = xkb.Keymap(lib, "us")
    out = []
    for char in text:
        if char == "\n":
            out.append("ret")
            continue
        found = target.key_for(char)
        if found is None:
            raise SystemExit(f"vm-drive: {layout!r} cannot type {char!r}")
        keycode, mods = found
        if "altgr" in mods:
            raise SystemExit(f"vm-drive: {char!r} needs AltGr on {layout!r}; not supported")
        base = us.read(keycode, ())
        if not base:
            raise SystemExit(f"vm-drive: keycode {keycode} has no US position to press")
        out.append(("shift-" if "shift" in mods else "") + NAMES.get(base, base))
    return out


class Monitor:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(5)
        self.sock.connect(path)
        time.sleep(0.3)
        self._drain()

    def _drain(self):
        # Read what the monitor has said, and stop as soon as it has said it: a blocking read
        # that waits out the socket's timeout costs that long for every key pressed (five
        # seconds each, once), which is slow, and worse, slower than a list widget's
        # type-ahead (about 400 ms), so "german" typed into the layout list arrived as "n".
        self.sock.settimeout(0.05)
        try:
            while True:
                if not self.sock.recv(65536):
                    break
        except OSError:
            pass
        finally:
            self.sock.settimeout(5)

    def command(self, line, pause=0.1):
        self.sock.sendall(line.encode() + b"\n")
        time.sleep(pause)
        self._drain()

    def keys(self, names, gap):
        for name in names:
            self.command(f"sendkey {name}", gap)

    def close(self):
        self.sock.close()


def screenshot(monitor, path):
    ppm = tempfile.mktemp(suffix=".ppm", dir=os.path.dirname(os.path.abspath(path)))
    monitor.command(f"screendump {ppm}", 1.0)
    deadline = time.time() + 10
    while not (os.path.exists(ppm) and os.path.getsize(ppm) > 0) and time.time() < deadline:
        time.sleep(0.2)
    data = open(ppm, "rb").read()
    os.unlink(ppm)
    magic, size, _maxval, pixels = data.split(b"\n", 3)
    if magic != b"P6":
        raise SystemExit("vm-drive: the screendump is not a PPM")
    width, height = map(int, size.split())

    def chunk(tag, body):
        c = struct.pack(">I", len(body)) + tag + body
        return c + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    rows = b"".join(b"\x00" + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(png)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--monitor", help="the QEMU monitor's unix socket")
    sub = parser.add_subparsers(dest="action", required=True)

    keys = sub.add_parser("keys")
    keys.add_argument("--gap", type=float, default=0.3)
    keys.add_argument("names", nargs="+", help="NAME or NAME*COUNT")

    for name in ("type", "translate"):
        p = sub.add_parser(name)
        p.add_argument("--layout", default="us")
        p.add_argument("--variant", default="")
        p.add_argument("--options", default="")
        p.add_argument("--gap", type=float, default=0.07)
        p.add_argument("--enter", action="store_true")
        p.add_argument("text")

    shot = sub.add_parser("shot")
    shot.add_argument("file")
    sub.add_parser("quit")
    args = parser.parse_args(argv)

    if args.action == "translate":
        print(" ".join(translate(args.text, args.layout, args.variant, args.options) + (["ret"] if args.enter else [])))
        return 0
    if not args.monitor:
        parser.error("--monitor is required")
    monitor = Monitor(args.monitor)
    try:
        if args.action == "keys":
            names = []
            for item in args.names:
                name, _, count = item.partition("*")
                names += [name] * int(count or 1)
            monitor.keys(names, args.gap)
        elif args.action == "type":
            names = translate(args.text, args.layout, args.variant, args.options)
            monitor.keys(names + (["ret"] if args.enter else []), args.gap)
        elif args.action == "shot":
            screenshot(monitor, args.file)
        elif args.action == "quit":
            monitor.command("quit")
    finally:
        monitor.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

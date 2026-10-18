#!/usr/bin/env python3
"""Type a string on one keyboard layout and read the same keystrokes on another.

This is what a password is, to a login: the key presses that were made, read through
whichever layout is active where they are checked. The installer's Users page sets a
password by reading key presses through the live session's layout; the login screen
checks it by reading key presses through the installed system's. A password is only
the same password if the two layouts read the keys the same way, and this makes that
checkable with the real xkb library rather than a table of known differences.

    xkb-decode.py type   TEXT  LAYOUT [VARIANT [OPTIONS [MODEL [GROUP]]]]
    xkb-decode.py decode KEYS  LAYOUT [VARIANT [OPTIONS [MODEL [GROUP]]]]

`type` prints the key presses that produce TEXT on that layout (a space-separated list
of keycode, or keycode+shift / +altgr), and fails if the layout cannot type a character
of it. `decode` takes such a list and prints what those key presses produce on the
layout given. Layout, variant and options are the xkb names, comma-separated for
several layouts, exactly as /etc/default/keyboard and setxkbmap spell them. GROUP is which
of those layouts is active (0, the first, unless it is given): the one a login starts in.

It uses libxkbcommon and xkb-data from the system through ctypes: no pip package, and
the same keymap compiler the compositor and the X server use.
"""
import ctypes
import ctypes.util
import sys

XKB_KEYCODE_MAX = 255
XKB_KEY_DOWN = 1
XKB_KEY_UP = 0
# xkb_state_component bits for xkb_state_update_mask
XKB_STATE_MODS_DEPRESSED = 1


def load():
    name = ctypes.util.find_library("xkbcommon") or "libxkbcommon.so.0"
    try:
        lib = ctypes.CDLL(name)
    except OSError as error:
        sys.exit(f"xkb-decode: libxkbcommon is not installed ({error}); install libxkbcommon0 and xkb-data")
    lib.xkb_context_new.restype = ctypes.c_void_p
    lib.xkb_context_new.argtypes = [ctypes.c_int]
    lib.xkb_keymap_new_from_names.restype = ctypes.c_void_p
    lib.xkb_keymap_new_from_names.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
    lib.xkb_state_new.restype = ctypes.c_void_p
    lib.xkb_state_new.argtypes = [ctypes.c_void_p]
    lib.xkb_keymap_mod_get_index.restype = ctypes.c_uint32
    lib.xkb_keymap_mod_get_index.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.xkb_state_update_mask.restype = ctypes.c_int
    lib.xkb_state_update_mask.argtypes = [ctypes.c_void_p] + [ctypes.c_uint32] * 6
    lib.xkb_state_key_get_utf8.restype = ctypes.c_int
    lib.xkb_state_key_get_utf8.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_size_t]
    lib.xkb_keymap_key_get_name.restype = ctypes.c_char_p
    lib.xkb_keymap_key_get_name.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    return lib


class RuleNames(ctypes.Structure):
    _fields_ = [(field, ctypes.c_char_p) for field in ("rules", "model", "layout", "variant", "options")]


class Keymap:
    def __init__(self, lib, layout, variant="", options="", model="", group=0):
        self.lib = lib
        self.group = group
        self.ctx = lib.xkb_context_new(0)
        names = RuleNames(None, model.encode() or None, layout.encode(), variant.encode() or None,
                          options.encode() or None)
        self.keymap = lib.xkb_keymap_new_from_names(self.ctx, ctypes.byref(names), 0)
        if not self.keymap:
            sys.exit(f"xkb-decode: xkb cannot compile layout={layout!r} variant={variant!r} options={options!r}")
        self.state = lib.xkb_state_new(self.keymap)
        self.shift = lib.xkb_keymap_mod_get_index(self.keymap, b"Shift")
        # ISO_Level3_Shift (AltGr) is mapped to Mod5 in every layout that has one.
        self.altgr = lib.xkb_keymap_mod_get_index(self.keymap, b"Mod5")

    def read(self, keycode, mods):
        mask = 0
        if "shift" in mods:
            mask |= 1 << self.shift
        if "altgr" in mods:
            mask |= 1 << self.altgr
        self.lib.xkb_state_update_mask(self.state, mask, 0, 0, 0, 0, self.group)
        buf = ctypes.create_string_buffer(16)
        self.lib.xkb_state_key_get_utf8(self.state, keycode, buf, 16)
        return buf.value.decode("utf-8", "replace")

    def key_for(self, char):
        """The first key press (keycode, modifiers) that types `char`, plainest first.

        The main block of the keyboard (keycodes 9-61: the letter, digit and punctuation
        rows) is searched before anything else, so a `/` is typed on the key a person
        would use for it and not on the keypad's.
        """
        for keycodes in (range(9, 62), range(62, XKB_KEYCODE_MAX + 1)):
            for mods in ((), ("shift",), ("altgr",), ("shift", "altgr")):
                for keycode in keycodes:
                    if not self.lib.xkb_keymap_key_get_name(self.keymap, keycode):
                        continue
                    if self.read(keycode, mods) == char:
                        return keycode, mods
        return None


def main(argv):
    if len(argv) < 4 or argv[1] not in ("type", "decode"):
        sys.exit(__doc__)
    action, text, layout = argv[1], argv[2], argv[3]
    variant = argv[4] if len(argv) > 4 else ""
    options = argv[5] if len(argv) > 5 else ""
    model = argv[6] if len(argv) > 6 else ""
    group = int(argv[7]) if len(argv) > 7 else 0
    keymap = Keymap(load(), layout, variant, options, model, group)
    if action == "type":
        presses = []
        for char in text:
            found = keymap.key_for(char)
            if found is None:
                sys.exit(f"xkb-decode: {layout!r} cannot type {char!r}")
            keycode, mods = found
            presses.append("+".join([str(keycode), *mods]))
        print(" ".join(presses))
    else:
        out = []
        for press in text.split():
            keycode, *mods = press.split("+")
            out.append(keymap.read(int(keycode), tuple(mods)))
        print("".join(out))


if __name__ == "__main__":
    main(sys.argv)

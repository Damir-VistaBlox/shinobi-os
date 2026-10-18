#!/usr/bin/env python3
"""What the wizard's keyboard page does with one choice, as Calamares 3.4.2 does it.

    calamares-keyboard.py argv|default|x11 LAYOUT [VARIANT [MODEL]]

prints one of three things for that selection:

    argv       the setxkbmap arguments the live system is given as the choice is made,
               one per line
    default    the /etc/default/keyboard written to the installed system
    x11        the /etc/X11/xorg.conf.d/00-keyboard.conf written there

This is a transcription, not an import: Calamares is a C++ program and the tests must run
without it. It follows src/modules/keyboard/Config.cpp (applyXkb, xkbmap_layout_args*) and
SetKeyboardLayoutJob.cpp (writeDefaultKeyboardData, writeX11Data) of v3.4.2, and
non-ascii-layouts, the table that decides which layouts get `us` in front. Both outputs were
compared with the real thing on a booted image (2026-10-18): choosing German on the wizard's
page ran `setxkbmap -model pc105 -layout de`, and the installed system's files were

    XKBMODEL="pc105"  XKBLAYOUT="de"  XKBVARIANT=""  BACKSPACE="guess"       (no XKBOPTIONS)
    Option "XkbLayout" "de"  Option "XkbVariant" ""                            (no model, no options)

and choosing Russian gave the live system `-layout us,ru -variant , -option grp:alt_shift_toggle`.

The detail that matters to a password is how the two disagree for a layout that cannot type
ASCII. The command line keeps an empty entry for the variant of the `us` it adds, so the
variant lines up with its layout (`-variant ,phonetic`). The files are written by removing
every empty entry, so the same variant is written alone (`XKBVARIANT="phonetic"`), which xkb
reads as the variant of the first layout. shinobi-keyboard repair undoes that.
"""
import sys

# The layouts Calamares puts `us` in front of: the first column of non-ascii-layouts. A
# layout in the table gets `us` as an additional layout with no variant, and the
# group-switch option when nothing else supplies one. Only the ones the tests use are listed;
# the real table has about fifty.
NON_ASCII = {"ru", "ua", "gr", "il", "ara", "bg", "by", "ge", "jp", "kr", "th"}
GROUP_SWITCH = "grp:alt_shift_toggle"


def selection(layout):
    additional = "us" if layout in NON_ASCII else ""
    return additional, "", (GROUP_SWITCH if additional else "")


def argv(layout, variant, model):
    additional, additional_variant, switch = selection(layout)
    out = ["-model", model]
    if additional:
        # xkbmap_layout_args_with_group_switch: the lists keep their empty entries.
        out += ["-layout", ",".join([additional, layout])]
        out += ["-variant", ",".join([additional_variant, variant])]
        out += ["-option", switch]
    else:
        out += ["-layout", layout]
        if variant:
            out += ["-variant", variant]
    return out


def remove_empty(items):
    return [item for item in items if item]


def default_keyboard(layout, variant, model):
    additional, additional_variant, switch = selection(layout)
    layouts = remove_empty([additional, layout])
    variants = remove_empty([additional_variant, variant])
    lines = [
        "# KEYBOARD CONFIGURATION FILE",
        "",
        "# Consult the keyboard(5) manual page.",
        "",
        f'XKBMODEL="{model}"',
        f'XKBLAYOUT="{",".join(layouts)}"',
        f'XKBVARIANT="{",".join(variants)}"',
    ]
    if additional:
        lines.append(f'XKBOPTIONS="{switch}"')
    lines.append('BACKSPACE="guess"')
    return "\n".join(lines) + "\n"


def x11_conf(layout, variant, model):
    additional, additional_variant, switch = selection(layout)
    layouts = remove_empty([additional, layout])
    variants = remove_empty([additional_variant, variant])
    lines = [
        "# Read and parsed by systemd-localed. It's probably wise not to edit this file",
        "# manually too freely.",
        'Section "InputClass"',
        '        Identifier "system-keyboard"',
        '        MatchIsKeyboard "on"',
        f'        Option "XkbLayout" "{",".join(layouts)}"',
        f'        Option "XkbVariant" "{",".join(variants)}"',
    ]
    if additional:
        lines.append(f'        Option "XkbOptions" "{switch}"')
    lines.append("EndSection")
    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("argv", "default", "x11"):
        sys.exit(__doc__)
    what, layout = sys.argv[1], sys.argv[2]
    variant = sys.argv[3] if len(sys.argv) > 3 else ""
    model = sys.argv[4] if len(sys.argv) > 4 else "pc105"
    if what == "argv":
        print("\n".join(argv(layout, variant, model)))
    elif what == "default":
        print(default_keyboard(layout, variant, model), end="")
    else:
        print(x11_conf(layout, variant, model), end="")


if __name__ == "__main__":
    main()

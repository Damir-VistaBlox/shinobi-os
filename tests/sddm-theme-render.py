#!/usr/bin/env python3
"""Run the Shinobi SDDM theme offscreen: look at its pixels, and drive its login logic.

usage: sddm-theme-render.py THEME_DIR

Run by tests/test-sddm-theme.sh when qml6 is available. It loads the theme's real Main.qml
with mock versions of the objects SDDM injects (`sddm`, `userModel`, `sessionModel`,
`keyboard`, `config`) and, for each scenario, either

  * renders a frame at 1280x800 with Qt's software renderer and no display, saves it as PPM
    (which Qt writes and this script can read with the standard library alone) and asserts
    on the pixels; or
  * calls the theme's own functions (submit(), step()) and the signals SDDM sends
    (loginFailed), and asserts on what the mock `sddm` was asked to do and on the state the
    screen ends up in. The state is reported by the harness through console.log, which is
    why Qt is made to log to stderr (a Qt built against journald sends it there instead and
    the script would see nothing).

The mock `keyboard` is shaped like SDDM's KeyboardModel (a list of layouts with a shortName,
and a writable currentLayout), so the layout chip is checked the way it is used: present with
two layouts and absent with one, relabelled when SDDM changes the layout, cycled by a click on
its MouseArea (tap(): the click handler runs, but only if a pointer could reach the item), and
followed through submit() to the layout that was active when login() went out.

Two things this once got wrong and now does not. The failed-login state was *faked* by
assigning it, so the real handler, which erased the red state in the instant it set it,
was never run; scenarios now go through submit() and a real loginFailed signal. And the
frame size and the logging depend on the environment (QT_SCALE_FACTOR, a journald-linked
Qt), so the environment is built explicitly and the frame size is asserted.

This tests the QML against SDDM's *interface*, not against SDDM. The greeter itself is
exercised by booting the image.
"""
import json
import os
import subprocess
import sys
import tempfile

W, H = 1280, 800

# Palette, as in Main.qml.
ACCENT = (0x89, 0xB4, 0xFA)
DANGER = (0xF3, 0x8B, 0xA8)
WARNING = (0xF9, 0xE2, 0xAF)
TEXT = (0xCD, 0xD6, 0xF4)
LINE = (0x45, 0x47, 0x5A)
BASE = (0x0A, 0x10, 0x1B)

# Where things are at 1280x800: the form is centred, the field is 320x52 at u = 1.
FIELD = (480, 500, 800, 566)
LEFT_OF_FIELD = (100, 505, 470, 560)
STATUS = (480, 566, 800, 600)
LOGO = (580, 280, 700, 400)
NAME_ROW = (460, 455, 820, 495)
WALLPAPER = (860, 60, 1260, 260)  # the ninja and the mist, top right
# The keyboard layout chip hangs off the field's right edge, centred on it (44x30 at 812,517).
CHIP = (806, 511, 870, 553)
FIELD_CENTRE_Y = 532
# The whole form, from the mark to the status line: below the clock, whose minute can roll
# over between two renders, and clear of the power buttons.
FORM = (440, 260, 900, 640)

# Expected, and not a defect: the bad-config scenario points at a wallpaper that is not there.
EXPECTED_COMPLAINTS = ("does-not-exist.jpg",)

TEMPLATE = """
import QtQuick

Item {
  id: wrap
  width: %(w)d
  height: %(h)d

  property var config: %(config)s
  // Shaped like SDDM's KeyboardModel: a writable currentLayout (an int) and a list of
  // layouts with a shortName each. A QtObject, not a plain object, so that writing
  // currentLayout notifies, as it does in the greeter. null is a greeter with no keyboard.
  property QtObject keyboard: %(keyboard)s
  property var calls: []
  // The layout that was active at the moment of each login(), kept apart from `calls` so
  // that what that records stays what it was.
  property var layoutsAtLogin: []
  property var layoutTrace: []
  property var tapResults: []
  property QtObject sddm: QtObject {
    property bool canPowerOff: true
    property bool canReboot: true
    property string hostName: "shinobi-test"
    signal loginFailed()
    signal loginSucceeded()
    function login(user, password, session) {
      wrap.calls.push([user, password.length, session])
      wrap.layoutsAtLogin.push(wrap.keyboard ? wrap.keyboard.currentLayout : -1)
    }
    function powerOff() {}
    function reboot() {}
  }
  property ListModel userModel: ListModel {
    property int lastIndex: 0
    property string lastUser: "testop"
    %(users)s
  }
  property ListModel sessionModel: ListModel {
    property int lastIndex: 0
    %(sessions)s
  }

  Loader { id: ld; anchors.fill: parent; source: "file://%(theme)s/Main.qml" }

  function field(item) {
    if (item.echoMode !== undefined) return item
    for (var i = 0; i < item.children.length; i++) {
      var found = field(item.children[i])
      if (found) return found
    }
    return null
  }

  function named(item, name) {
    if (item.objectName === name) return item
    for (var i = 0; i < item.children.length; i++) {
      var found = named(item.children[i], name)
      if (found) return found
    }
    return null
  }

  // Clicks the layout chip. A pointer can only reach an item that is shown and enabled,
  // so this does not "click" one that is not: emitting the signal alone would bypass
  // both, and a chip that stayed clickable while hidden would pass.
  function tap(it) {
    var area = named(it, "layoutChipArea")
    var ok = !!area && area.visible && area.enabled
    if (ok) {
      area.clicked(null)
      wrap.layoutTrace.push(wrap.keyboard.currentLayout)
    }
    wrap.tapResults.push(ok)
    return ok
  }

  function report(it) {
    var f = field(it)
    var chip = named(it, "layoutChip")
    var spot = chip ? chip.mapToItem(wrap, 0, 0) : null
    console.log("STATE " + JSON.stringify({
      calls: wrap.calls,
      layoutsAtLogin: wrap.layoutsAtLogin,
      layoutTrace: wrap.layoutTrace,
      tapResults: wrap.tapResults,
      layout: wrap.keyboard ? wrap.keyboard.currentLayout : null,
      layoutCount: it.layoutCount,
      layoutName: it.layoutName,
      chip: chip ? { visible: chip.visible, x: spot.x, y: spot.y, w: chip.width, h: chip.height } : null,
      failed: it.failed,
      busy: it.busy,
      notice: it.notice,
      text: f ? f.text.length : -1,
      focus: f ? f.activeFocus : null,
      echoMode: f ? f.echoMode : null,
      passwordCharacter: f ? f.passwordCharacter : null,
      userIndex: it.userIndex,
      login: it.currentLogin
    }))
  }

  Timer {
    interval: 350
    running: true
    onTriggered: {
      var it = ld.item
      if (!it) { Qt.quit(); return }
      %(actions)s
      later.start()
    }
  }
  Timer {
    id: later
    interval: %(delay)d
    onTriggered: { wrap.report(ld.item); grab.start() }
  }
  Timer {
    id: grab
    interval: 450
    onTriggered: wrap.grabToImage(function (r) { r.saveToFile("%(out)s"); Qt.quit() })
  }
}
"""

ONE = 'ListElement { name: "testop"; realName: "Test Operator" }'
TWO = ONE + '\n    ListElement { name: "alice"; realName: "Alice Example" }'
SESSION = 'ListElement { name: "Hyprland" }'
GOOD_CONFIG = '({ background: "background.jpg", accent: "#89b4fa" })'
FAIL_FLOW = 'it.passwordText = "wrong"; it.submit(); sddm.loginFailed()'
# What SDDM's keyboard model reports. One layout is an ordinary US-only system; two is
# `us,ru` with Alt+Shift to toggle, which is the case the chip exists for.
ONE_LAYOUT = ["us"]
TWO_LAYOUTS = ["us", "ru"]

SCENARIOS = {
    "empty": dict(),
    "typed": dict(actions='it.passwordText = "correct horse battery staple"'),
    "failed": dict(actions=FAIL_FLOW),
    "capslock": dict(caps="true"),
    "two-users": dict(users=TWO),
    "bad-config": dict(config='({ background: "does-not-exist.jpg", accent: "" })'),
    "no-config": dict(config="null"),
    # Behaviour: what the screen asks SDDM to do, and what state it is left in.
    "submit": dict(actions='it.passwordText = "hunter2"; it.submit(); it.submit()'),
    "submit-empty": dict(actions="it.submit()"),
    "step-then-submit": dict(users=TWO, actions='it.step(1); it.passwordText = "pw"; it.submit()'),
    "step-while-busy": dict(users=TWO, actions='it.passwordText = "pw"; it.submit(); it.step(1)'),
    "no-session": dict(sessions="", actions='it.passwordText = "pw"; it.submit()'),
    "watchdog": dict(actions='it.loginTimeout = 250; it.passwordText = "pw"; it.submit()', delay=800),
    "failed-then-retry": dict(actions=FAIL_FLOW + '; it.passwordText = "again"; it.submit()'),
    # The keyboard layout chip. "layout-hidden" is also the one-layout frame.
    "layout-hidden": dict(actions="tap(it)"),
    "layouts": dict(layouts=TWO_LAYOUTS),
    # What Alt+Shift does: SDDM changes currentLayout and the chip follows.
    "layouts-switched": dict(layouts=TWO_LAYOUTS, actions="keyboard.currentLayout = 1"),
    "layouts-appear": dict(actions='keyboard.layouts = [{ shortName: "us" }, { shortName: "ru" }]'),
    "layout-click": dict(layouts=["us", "ru", "de"], actions="tap(it); tap(it); tap(it)"),
    "layout-then-submit": dict(layouts=TWO_LAYOUTS, actions='it.passwordText = "hunter2"; tap(it); it.submit(); it.submit()'),
    "layout-after-failure": dict(layouts=TWO_LAYOUTS, actions=FAIL_FLOW + '; tap(it); it.passwordText = "right"; it.submit()'),
    "no-keyboard": dict(layouts=None),
}


def keyboard_qml(caps, layouts):
    """The mock `keyboard`: capsLock, currentLayout and a list of layouts, or null."""
    if layouts is None:
        return "null"
    entries = ", ".join('{ shortName: "%s", longName: "%s" }' % (n, n) for n in layouts)
    return "QtObject { property bool capsLock: %s; property var layouts: [%s]; property int currentLayout: 0 }" % (caps, entries)


class Frame:
    def __init__(self, path):
        data = open(path, "rb").read()
        # P6 <w> <h> <maxval><one whitespace byte><binary RGB>. Parsed by hand: splitting on
        # whitespace would also eat a first pixel byte of 0x0A, which is this theme's base
        # colour, and shift every channel by one.
        pos = 0
        tokens = []
        while len(tokens) < 4:
            while data[pos:pos + 1].isspace():
                pos += 1
            start = pos
            while not data[pos:pos + 1].isspace():
                pos += 1
            tokens.append(data[start:pos])
        pos += 1  # the single whitespace byte after maxval
        if tokens[0] != b"P6":
            raise ValueError("not a binary PPM")
        self.w, self.h = int(tokens[1]), int(tokens[2])
        self.px = data[pos:]

    def at(self, x, y):
        i = (y * self.w + x) * 3
        return self.px[i], self.px[i + 1], self.px[i + 2]

    def count(self, color, box, tol=28):
        x0, y0, x1, y1 = box
        n = 0
        for y in range(y0, y1):
            row = (y * self.w) * 3
            for x in range(x0, x1):
                i = row + x * 3
                if (abs(self.px[i] - color[0]) + abs(self.px[i + 1] - color[1]) + abs(self.px[i + 2] - color[2])) <= tol:
                    n += 1
        return n

    def differing(self, other, box, skip=None):
        """How many pixels of `box` differ from the same pixels of `other`, leaving out
        `skip` (a box) if given."""
        x0, y0, x1, y1 = box
        n = 0
        for y in range(y0, y1):
            for x in range(x0, x1):
                if skip and skip[0] <= x < skip[2] and skip[1] <= y < skip[3]:
                    continue
                if self.at(x, y) != other.at(x, y):
                    n += 1
        return n

    def distinct(self, box):
        """How many different colours a region holds: a photograph has hundreds, a plain
        fill has one. (The wallpaper is so dark that its average colour is the base
        colour's, so the mean cannot tell the two apart.)"""
        x0, y0, x1, y1 = box
        return len({self.at(x, y) for y in range(y0, y1, 2) for x in range(x0, x1, 2)})

    def mean(self, box):
        x0, y0, x1, y1 = box
        total = [0, 0, 0]
        n = 0
        for y in range(y0, y1, 2):
            for x in range(x0, x1, 2):
                p = self.at(x, y)
                total[0] += p[0]
                total[1] += p[1]
                total[2] += p[2]
                n += 1
        return tuple(t / n for t in total)


checks = 0
failures = 0


def check(label, condition, detail=""):
    global checks, failures
    checks += 1
    if condition:
        print(f"  ok   {label}")
    else:
        failures += 1
        print(f"  FAIL {label}" + (f"\n       {detail}" if detail else ""))


def environment():
    """An environment that cannot change the result: no display scaling or platform theme
    inherited from the user's session, and Qt logging to stderr even where it was built to
    send it to the journal."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(("QT_", "QML"))}
    env.update(
        QT_QPA_PLATFORM="offscreen",
        QT_QUICK_BACKEND="software",
        QT_ENABLE_HIGHDPI_SCALING="0",
        QT_FORCE_STDERR_LOGGING="1",
    )
    return env


def render(theme, workdir, name, opts):
    out = os.path.join(workdir, name + ".ppm")
    qml = TEMPLATE % dict(
        w=W,
        h=H,
        config=opts.get("config", GOOD_CONFIG),
        keyboard=keyboard_qml(opts.get("caps", "false"), opts.get("layouts", ONE_LAYOUT)),
        users=opts.get("users", ONE),
        sessions=opts.get("sessions", SESSION),
        actions=opts.get("actions", ""),
        delay=opts.get("delay", 50),
        theme=theme,
        out=out,
    )
    path = os.path.join(workdir, name + ".qml")
    with open(path, "w") as handle:
        handle.write(qml)
    try:
        proc = subprocess.run(["qml6", path], capture_output=True, text=True, env=environment(), timeout=40)
        log = proc.stdout + proc.stderr
    except subprocess.TimeoutExpired as exc:
        partial = exc.stdout.decode(errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        log = "TIMED OUT after 40 s\n" + partial
    state = {}
    for line in log.splitlines():
        if "STATE " in line:
            try:
                state = json.loads(line.split("STATE ", 1)[1])
            except ValueError:
                pass
    frame = None
    if os.path.exists(out) and os.path.getsize(out) > 0:
        try:
            frame = Frame(out)
        except ValueError:
            frame = None
    return frame, state, log


def main(theme):
    frames, states, logs = {}, {}, {}
    with tempfile.TemporaryDirectory() as workdir:
        for name, opts in SCENARIOS.items():
            frames[name], states[name], logs[name] = render(theme, workdir, name, opts)

    print("== every scenario runs, QML loads the theme without complaint, and the frame is the size asked for ==")
    for name in SCENARIOS:
        check(f"'{name}' produced a frame", frames[name] is not None, logs[name][:300])
    complaints = []
    for name, log in logs.items():
        for line in log.splitlines():
            if "Main.qml" in line and not any(e in line for e in EXPECTED_COMPLAINTS):
                complaints.append(f"{name}: {line.strip()}")
    check("no scenario makes QML complain about Main.qml", not complaints, "\n       ".join(complaints[:5]))
    if any(f is None for f in frames.values()):
        return
    check(f"the frames are {W}x{H}, so the boxes below are where they are assumed to be",
          all((f.w, f.h) == (W, H) for f in frames.values()),
          str({n: (f.w, f.h) for n, f in frames.items() if (f.w, f.h) != (W, H)}))

    print("\n== the form is on screen, in the colour of its state ==")
    f = frames["empty"]
    check("the empty field has the accent border", f.count(ACCENT, FIELD) > 400, f"accent pixels: {f.count(ACCENT, FIELD)}")
    check("the logo is drawn (the ring is the accent colour)", f.count(ACCENT, LOGO) > 300, f"accent pixels: {f.count(ACCENT, LOGO)}")
    check("the wordmark is in the accent colour", f.count(ACCENT, (500, 410, 780, 445)) > 100)
    check("nothing is red or yellow before anything has gone wrong", f.count(DANGER, STATUS) + f.count(WARNING, STATUS) == 0)

    f = frames["failed"]
    check("a login that fails turns the border red (through submit() and a real loginFailed)", f.count(DANGER, FIELD) > 400, f"danger pixels: {f.count(DANGER, FIELD)}")
    check("and the accent border is gone", f.count(ACCENT, FIELD) < 150, f"accent pixels: {f.count(ACCENT, FIELD)}")
    check("and says so underneath", f.count(DANGER, STATUS) > 30, f"danger pixels: {f.count(DANGER, STATUS)}")

    f = frames["capslock"]
    check("Caps Lock is announced", f.count(WARNING, STATUS) > 20, f"warning pixels: {f.count(WARNING, STATUS)}")

    f = frames["typed"]
    check("typed characters appear in the field as dots", f.count(TEXT, FIELD) > 40, f"text pixels: {f.count(TEXT, FIELD)}")
    check("and a password longer than the box does not spill out of it", f.count(TEXT, LEFT_OF_FIELD) == 0, f"text pixels outside: {f.count(TEXT, LEFT_OF_FIELD)}")

    print("\n== accounts ==")
    one, two = frames["empty"], frames["two-users"]
    differing = sum(1 for x in range(NAME_ROW[0], NAME_ROW[2]) for y in range(NAME_ROW[1], NAME_ROW[3]) if one.at(x, y) != two.at(x, y))
    check("with two accounts the name row offers a choice (arrows appear)", differing > 20, f"differing pixels: {differing}")

    print("\n== the keyboard layout chip (a second layout, such as us,ru, is otherwise invisible while a password is typed) ==")
    plain, hidden, two = frames["empty"], frames["layout-hidden"], frames["layouts"]
    s = states["layout-hidden"]
    check("with one layout there is no chip", (s.get("chip") or {}).get("visible") is not True and s.get("layoutCount") == 1, f"chip: {s.get('chip')}")
    check("and nothing is drawn where it would be",
          hidden.count(TEXT, CHIP, tol=150) == 0 and hidden.count(LINE, CHIP) == 0,
          f"label pixels: {hidden.count(TEXT, CHIP, tol=150)}, outline pixels: {hidden.count(LINE, CHIP)}")
    check("and the form is exactly what it was before the chip existed", hidden.differing(plain, FORM) == 0, f"differing pixels: {hidden.differing(plain, FORM)}")
    check("a click that cannot reach a hidden chip changes nothing",
          s.get("tapResults") == [False] and s.get("layout") == 0 and s.get("layoutTrace") == [], f"state: {s}")
    s = states["no-keyboard"]
    check("a greeter with no keyboard object at all shows no chip, and the form is still there",
          (s.get("chip") or {}).get("visible") is not True and s.get("layoutCount") == 0 and frames["no-keyboard"].count(ACCENT, FIELD) > 400, f"state: {s}")

    s = states["layouts"]
    chip = s.get("chip") or {}
    check("with two layouts the chip appears, naming the current one", chip.get("visible") is True and s.get("layoutName") == "US", f"state: {s}")
    # The label is 13 px of anti-aliased glyphs, so few of its pixels reach the exact text
    # colour: the tolerance is wide, and the hidden frame (0 at any tolerance) is the control.
    check("it is drawn: an outline, and a label in the text colour",
          two.count(LINE, CHIP) > 80 and two.count(TEXT, CHIP, tol=150) > 15,
          f"outline pixels: {two.count(LINE, CHIP)}, label pixels: {two.count(TEXT, CHIP, tol=150)}")
    check("beside the field, level with it, and not over it",
          chip.get("x", 0) >= FIELD[2] and chip.get("x", 9999) + chip.get("w", 0) <= CHIP[2]
          and abs(chip.get("y", 0) + chip.get("h", 0) / 2 - FIELD_CENTRE_Y) <= 1,
          f"chip: {chip}")
    check("and the rest of the form has not moved", two.differing(plain, FORM, skip=CHIP) == 0, f"differing pixels: {two.differing(plain, FORM, skip=CHIP)}")
    check("the field keeps its accent border", two.count(ACCENT, FIELD) > 400)

    s = states["layouts-switched"]
    check("when SDDM changes the layout (Alt+Shift) the chip follows", s.get("layoutName") == "RU" and s.get("layout") == 1, f"state: {s}")
    check("and is redrawn with the other name", frames["layouts-switched"].differing(two, CHIP) > 20, f"differing pixels: {frames['layouts-switched'].differing(two, CHIP)}")
    check("and nothing else on the screen changes with it", frames["layouts-switched"].differing(two, FORM, skip=CHIP) == 0)
    s = states["layouts-appear"]
    check("layouts that arrive after the screen has loaded make the chip appear", (s.get("chip") or {}).get("visible") is True and s.get("layoutName") == "US", f"state: {s}")

    s = states["layout-click"]
    check("a click moves to the next layout, and the last wraps to the first (three layouts, three clicks)",
          s.get("tapResults") == [True, True, True] and s.get("layoutTrace") == [1, 2, 0] and s.get("layoutName") == "US", f"state: {s}")
    check("and the password field keeps the keyboard focus", s.get("focus") is True, f"state: {s}")

    print("\n== the chip and the real login path ==")
    s = states["layout-then-submit"]
    check("clicking the chip does not clear what was typed", s.get("text") == 7 and s.get("layoutName") == "RU", f"state: {s}")
    check("and submitting still asks SDDM to log in, once, as before", s.get("calls") == [["testop", 7, 0]], f"calls: {s.get('calls')}")
    check("with the layout the operator switched to active when the login went out", s.get("layoutsAtLogin") == [1], f"layouts at login: {s.get('layoutsAtLogin')}")
    s = states["layout-after-failure"]
    check("after a failed login the retry goes out under the layout switched to (through a real loginFailed)",
          len(s.get("calls", [])) == 2 and s.get("layoutsAtLogin") == [0, 1] and s["calls"][1][1] == 5, f"state: {s}")
    check("and is an ordinary attempt: failure cleared, field locked", s.get("failed") is False and s.get("busy") is True, f"state: {s}")

    print("\n== what the screen asks SDDM to do ==")
    s = states["empty"]
    check("the password field masks what is typed (checked on the running item, not in the source)", s.get("echoMode") == 2, f"echoMode: {s.get('echoMode')}")
    check("and shows a bullet, not the characters", s.get("passwordCharacter") == "•", f"passwordCharacter: {s.get('passwordCharacter')!r}")
    s = states["submit"]
    check("submitting asks SDDM to log in once, with the account, the password's length and the session",
          s.get("calls") == [["testop", 7, 0]], f"calls: {s.get('calls')}")
    check("and a second submit while that login is in flight is ignored", len(s.get("calls", [])) == 1)
    check("the field is locked while SDDM works", s.get("busy") is True)
    check("submitting nothing asks SDDM for nothing", states["submit-empty"].get("calls") == [], f"calls: {states['submit-empty'].get('calls')}")
    s = states["step-then-submit"]
    check("choosing the second account and submitting logs that account in", s.get("calls") == [["alice", 2, 0]], f"calls: {s.get('calls')}")
    s = states["step-while-busy"]
    check("the account cannot be changed while a login is in flight", s.get("login") == "testop" and s.get("userIndex") == 0, f"state: {s}")

    print("\n== what state it is left in ==")
    s = states["failed"]
    check("after a failed login the red state is still set (it was erased in the same instant before)", s.get("failed") is True, f"state: {s}")
    check("the field is empty and unlocked", s.get("text") == 0 and s.get("busy") is False, f"state: {s}")
    check("and has the keyboard focus again", s.get("focus") is True, f"state: {s}")
    s = states["failed-then-retry"]
    check("the next attempt after a failure is sent to SDDM", len(s.get("calls", [])) == 2 and s["calls"][1][1] == 5, f"calls: {s.get('calls')}")
    check("and clears the failure while it runs", s.get("failed") is False and s.get("busy") is True, f"state: {s}")
    s = states["no-session"]
    check("with no desktop session installed nothing is sent to SDDM (which would drop it without a word)", s.get("calls") == [], f"calls: {s.get('calls')}")
    check("and the screen says why, and stays usable", "session" in (s.get("notice") or "") and s.get("busy") is False, f"state: {s}")
    s = states["watchdog"]
    check("a login SDDM never answers gives the field back, with a message", s.get("busy") is False and "did not answer" in (s.get("notice") or ""), f"state: {s}")
    check("and focus too", s.get("focus") is True, f"state: {s}")

    print("\n== a theme that cannot read its settings still works ==")
    f = frames["bad-config"]
    check("a missing wallpaper falls back to a plain base colour", f.distinct(WALLPAPER) < 5 and all(abs(m - b) < 14 for m, b in zip(f.mean(WALLPAPER), BASE)), f"colours: {f.distinct(WALLPAPER)}, mean: {f.mean(WALLPAPER)}")
    check("and the form is still there, with the default accent", f.count(ACCENT, FIELD) > 400)
    f = frames["no-config"]
    check("no theme.conf at all: the form is still there", f.count(ACCENT, FIELD) > 400)
    check("and so is the wallpaper (the default is the bundled image, not the plain fallback)", f.distinct(WALLPAPER) > 30, f"colours: {f.distinct(WALLPAPER)}")
    check("a good configuration shows the wallpaper too", frames["empty"].distinct(WALLPAPER) > 30)


if __name__ == "__main__":
    main(os.path.abspath(sys.argv[1]))
    print()
    print(f"{checks - failures}/{checks} checks passed")
    sys.exit(1 if failures else 0)

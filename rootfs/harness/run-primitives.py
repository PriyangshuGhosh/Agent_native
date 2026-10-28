#!/usr/bin/env python3
"""Guest probe: exercises each primitive and reports JSON lines on ttyS0 (contract: tests/gate-01.sh, gate-03.sh).
Standalone (Cycle 01) it starts D-Bus, AT-SPI and cage itself; under agent-init (Cycle 03+) those already run."""
import json, os, subprocess, sys, time, traceback

TTY = open("/dev/ttyS0", "w", buffering=1)
LOG = open("/tmp/harness.log", "a", buffering=1)
OUTPUT = "HEADLESS-1"
MANAGED = "WAYLAND_DISPLAY" in os.environ  # agent-init exports it before starting the session


def emit(event, **kw):
    ms = time.clock_gettime_ns(time.CLOCK_BOOTTIME) // 1_000_000
    TTY.write(json.dumps({"ts_ms": ms, "event": event, **kw}) + "\n")


def debug(msg):
    TTY.write("# " + msg.replace("\n", "\n# ") + "\n")  # non-JSON: the gate ignores it


def wait_for(what, fn, timeout=30.0):
    end, last = time.monotonic() + timeout, None
    while time.monotonic() < end:
        try:
            v = fn()
            if v:
                return v
        except Exception as ex:
            last = ex
        time.sleep(0.05)
    raise TimeoutError(f"{what} (last error: {last!r})")


def start_session():
    if MANAGED:
        return
    run = "/run/user/0"
    os.makedirs(run, mode=0o700, exist_ok=True)
    os.environ.update(XDG_RUNTIME_DIR=run, HOME="/root", LANG="C.UTF-8")
    addr = subprocess.check_output(
        ["dbus-daemon", "--session", "--fork", "--nopidfile", "--print-address=1"], stderr=LOG, text=True)
    os.environ["DBUS_SESSION_BUS_ADDRESS"] = addr.strip()
    subprocess.Popen(["/usr/libexec/at-spi-bus-launcher", "--launch-immediately"], stdout=LOG, stderr=LOG)


def make_keyboard():
    from evdev import UInput, ecodes as e
    # Created before cage starts so libinput enumerates it (no hotplug dependency).
    ui = UInput({e.EV_KEY: list(range(e.KEY_ESC, e.KEY_MICMUTE))}, name="gate01-kbd")
    subprocess.run(["udevadm", "settle"], stdout=LOG, stderr=LOG)
    return ui


def start_cage():
    env = dict(os.environ, WLR_BACKENDS="headless,libinput", LIBSEAT_BACKEND="noop",
               WLR_RENDERER="pixman", WLR_LIBINPUT_NO_DEVICES="1", GDK_BACKEND="wayland")
    if not MANAGED:
        subprocess.Popen(["cage", "--", "mousepad"], env=env, stdout=LOG, stderr=LOG)
        os.environ["WAYLAND_DISPLAY"] = "wayland-0"
    # grim -o fails unless an output with exactly this name exists.
    wait_for("cage output " + OUTPUT, lambda: subprocess.run(
        ["grim", "-t", "ppm", "-o", OUTPUT, "/tmp/probe.ppm"], stdout=LOG, stderr=LOG).returncode == 0)
    emit("COMPOSITOR_READY", output=OUTPUT)


def tree(a):
    return {"role": a.get_role_name(), "name": a.get_name(),
            "children": [tree(a.get_child_at_index(i)) for i in range(a.get_child_count())]}


def walk(t):
    yield t
    for c in t["children"]:
        yield from walk(c)


def find_text(a, Atspi):
    if a.get_role() == Atspi.Role.TEXT and a.get_state_set().contains(Atspi.StateType.EDITABLE):
        return a
    for i in range(a.get_child_count()):
        r = find_text(a.get_child_at_index(i), Atspi)
        if r:
            return r


def atspi_steps(kbd):
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi

    desktop = Atspi.get_desktop(0)
    app = wait_for("mousepad on AT-SPI", lambda: next(
        (a for a in (desktop.get_child_at_index(i) for i in range(desktop.get_child_count()))
         if a and "mousepad" in a.get_name().lower()), None))
    text = wait_for("mousepad text widget", lambda: find_text(app, Atspi))
    t = tree(app)
    with open("/tmp/mousepad-tree.json", "w") as f:
        json.dump(t, f)
    emit("INTERACTION_CYCLE_VERIFIED", primitive="atspi_tree", app="mousepad", nodes=sum(1 for _ in walk(t)))

    # Call via the interface: Accessible.get_text is a deprecated iface getter that shadows Text.get_text.
    def read():
        return Atspi.Text.get_text(text, 0, -1)

    def settle(want):
        try:
            wait_for("read-back", lambda: read() == want, 5)
        except TimeoutError:
            pass  # emit the mismatch; the gate decides
        return read()

    want = "gate01-atspi"
    Atspi.EditableText.set_text_contents(text, want)
    emit("INTERACTION_CYCLE_VERIFIED", primitive="atspi_action", expected=want, actual=settle(want))

    from evdev import ecodes as e

    def press(key):
        for val in (1, 0):
            kbd.write(e.EV_KEY, key, val)
            kbd.syn()
            time.sleep(0.01)

    def clear():
        Atspi.EditableText.set_text_contents(text, "")
        wait_for("text cleared", lambda: read() == "", 5)
        return True

    # Under agent-init the keyboard is hotplugged into a running cage: probe until libinput delivers keys.
    def keys_live():
        clear()
        press(e.KEY_X)
        end = time.monotonic() + 0.5
        while time.monotonic() < end and read() == "":
            time.sleep(0.05)
        return read() != "" and clear()

    wait_for("uinput keyboard live", keys_live, 15)
    want = "gate01-uinput"
    for ch in want:
        press(e.KEY_MINUS if ch == "-" else getattr(e, "KEY_" + ch.upper()))
    emit("INTERACTION_CYCLE_VERIFIED", primitive="uinput", expected=want, actual=settle(want))


def screencopy():
    frames, t0 = 15, time.monotonic()
    for _ in range(frames):
        subprocess.run(["grim", "-t", "ppm", "-o", OUTPUT, "/tmp/frame.ppm"], check=True, stderr=LOG)
        with open("/tmp/frame.ppm", "rb") as f:
            assert f.read(2) == b"P6", "grim wrote a non-PPM frame"
    fps = frames / (time.monotonic() - t0)
    emit("INTERACTION_CYCLE_VERIFIED", primitive="screencopy", frames=frames, fps=round(fps, 1))


def main():
    try:
        start_session()
        kbd = make_keyboard()
        start_cage()
        atspi_steps(kbd)
        screencopy()
    except Exception:
        debug(traceback.format_exc())
        LOG.flush()
        with open("/tmp/harness.log") as f:
            debug("harness.log tail:\n" + "".join(f.readlines()[-40:]))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

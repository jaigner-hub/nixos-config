#!/usr/bin/env python3
"""Live HDHomeRun signal-stats viewer for antenna aiming.

Pins both tuners to two virtual channels and refreshes signal-strength /
signal-quality / symbol-quality / streaming-rate side-by-side once per
second. Watch the Signal Quality numbers while rotating or tilting the
antenna — multipath nulls move with sub-degree rotations, so this gives
real-time feedback the ATSC scan can't.

Usage:
    scripts/hdhomerun-stats.py                       # defaults to 9.1 and 11.1
    scripts/hdhomerun-stats.py 5.1 11.1              # any two virtual channels
    scripts/hdhomerun-stats.py 5.1 11.1 10.0.0.205   # explicit HDHomeRun IP

Reading the numbers:
    Signal Strength = RF energy reaching the demod (0-100%). 100% with no
        lock means strong signal but unusable — almost always multipath.
    Signal Quality  = demodulator SNR estimate. >70% locks cleanly,
        50-70% is marginal (errors), <50% rarely locks.
    Symbol Quality  = post-FEC error rate. 100% = clean decode.

Press Ctrl-C to release the tuners.
"""
import ctypes
import re
import signal
import subprocess
import sys
import time
import urllib.request

# Make subprocess.Popen children inherit a parent-death signal so curl
# streams die when the Python parent dies, even on SIGKILL (e.g. from
# `timeout`). Without this, orphaned curls keep streaming forever and
# hold the HDHomeRun tuners locked until the device's own idle timeout.
_PR_SET_PDEATHSIG = 1
def _set_pdeathsig():  # runs in the child between fork and exec
    try:
        ctypes.CDLL("libc.so.6").prctl(_PR_SET_PDEATHSIG, signal.SIGTERM)
    except Exception:
        pass

DEFAULT_HDHR = "10.0.0.205"
DEFAULT_CHANNELS = ["9.1", "11.1"]
ROW_RE = re.compile(r"<tr><td>([^<]*)</td><td>([^<]*)</td></tr>")
FIELDS = [
    "Virtual Channel",
    "Frequency",
    "Modulation Lock",
    "Signal Strength",
    "Signal Quality",
    "Symbol Quality",
    "Streaming Rate",
]


def parse_args(argv):
    args = argv[1:]
    hdhr = DEFAULT_HDHR
    channels = list(DEFAULT_CHANNELS)
    if args and "." in args[-1] and args[-1].count(".") == 3:
        hdhr = args.pop()
    if len(args) == 2:
        channels = args
    elif args:
        sys.exit(f"usage: {sys.argv[0]} [CH1 CH2] [HDHR_IP]")
    return hdhr, channels


def fetch_tuner(hdhr, n):
    try:
        with urllib.request.urlopen(
            f"http://{hdhr}/tuners.html?page=tuner{n}", timeout=3
        ) as r:
            html = r.read().decode("utf-8", errors="replace")
    except Exception as e:
        return {"_error": str(e)}
    return dict(ROW_RE.findall(html))


def match_tuner(tuners, ch):
    """Find which tuner holds `ch` based on its actual Virtual Channel field.

    HDHomeRun /auto/ doesn't guarantee a stable channel->tuner mapping, so
    we have to read what each tuner actually has rather than assume order.
    """
    for i, t in enumerate(tuners):
        vc = t.get("Virtual Channel", "")
        if vc.startswith(ch + " ") or vc == ch:
            return i, t
    return None, None


def render(tuners, channels):
    def col(t, ch, idx):
        if t is None:
            return [f"  (tuner not yet tuned to {ch})"] + [""] * len(FIELDS)
        if "_error" in t:
            return [f"  ! {t['_error']}"] + [""] * len(FIELDS)
        # Header includes which physical tuner ended up with this channel.
        out = [f"  channel: {ch}   (tuner {idx})"]
        for f in FIELDS:
            if f == "Virtual Channel":
                continue
            out.append(f"  {f + ':':<17} {t.get(f, '--')}")
        return out

    pairs = [match_tuner(tuners, ch) for ch in channels]
    headers = [
        f"{(tuners[i].get('Virtual Channel') or ch).upper() if i is not None else ch.upper()}"
        for ch, (i, _) in zip(channels, pairs)
    ]
    width = 38
    rows = [headers[0].ljust(width) + " | " + headers[1]]
    cols = [col(t, ch, i) for (i, t), ch in zip(pairs, channels)]
    for l, r in zip(*cols):
        rows.append(f"{l.ljust(width)} | {r.lstrip()}")
    rows.append("")
    rows.append(
        f"  updated: {time.strftime('%H:%M:%S')}   (Ctrl-C to release tuners)"
    )
    return rows


def main():
    hdhr, channels = parse_args(sys.argv)

    # Open a stream per channel so HDHomeRun keeps the tuner locked. Two
    # important gotchas with /auto/:
    #   1. Starting both curls simultaneously can race — the HDHomeRun
    #      occasionally routes the second request to the tuner that already
    #      took the first channel, ending up with both tuners on the same
    #      channel. Sleeping between starts gives the first tune time to
    #      claim a tuner so the second has to pick the other one.
    #   2. A failed lock (e.g. a channel that can't be received) causes the
    #      curl subprocess to exit. We re-spawn dead streams every render
    #      tick so the tuner keeps trying — useful when antenna-aiming since
    #      you want the tuner to re-attempt as you move it.
    streams = []

    def start_curl(ch):
        return subprocess.Popen(
            ["curl", "-s", "-o", "/dev/null", f"http://{hdhr}:5004/auto/v{ch}"],
            stdin=subprocess.DEVNULL,
            preexec_fn=_set_pdeathsig,
        )

    def cleanup(*_):
        for p in streams:
            if p and p.poll() is None:
                p.terminate()
        for p in streams:
            if not p:
                continue
            try:
                p.wait(timeout=2)
            except subprocess.TimeoutExpired:
                p.kill()
        sys.stdout.write("\nstreams released\n")
        sys.stdout.flush()
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    # Sequence the curl spawns so the HDHomeRun lands them on distinct tuners.
    for ch in channels:
        streams.append(start_curl(ch))
        time.sleep(2)

    first = True
    while True:
        # Re-spawn any curl that has exited (failed lock, network hiccup).
        # Without this, a channel that briefly drops never gets retried.
        for i, ch in enumerate(channels):
            if streams[i].poll() is not None:
                streams[i] = start_curl(ch)

        rows = render([fetch_tuner(hdhr, 0), fetch_tuner(hdhr, 1)], channels)
        if not first:
            # ANSI: cursor up by the previous block's height to overwrite in place.
            sys.stdout.write(f"\033[{len(rows)}A")
        for r in rows:
            # Pad to 80 cols to wipe any leftover characters from a longer prior line.
            sys.stdout.write(r.ljust(80) + "\n")
        sys.stdout.flush()
        first = False
        time.sleep(1)


if __name__ == "__main__":
    main()

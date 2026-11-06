#!/usr/bin/env python3
"""Stand-in for the public luna-send client used by offline tests.

Exits with an empty body when stdin is a hung-up pipe, which is the
input_closed path in luna-send.cpp. Does not evaluate message arguments.
"""

import json
import os
import select
import sys


def stdin_hungup():
    poll = select.poll()
    poll.register(0, select.POLLIN | select.POLLERR | select.POLLHUP)
    events = poll.poll(100)
    return any(flags & (select.POLLHUP | select.POLLERR) for _, flags in events)


def main():
    argv = sys.argv[1:]
    try:
        hungup = stdin_hungup()
    except OSError:
        hungup = True

    log_path = os.environ.get("LUNA_MOCK_LOG")
    if log_path:
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"hup": hungup, "argv": argv}) + "\n")

    forced = os.environ.get("LUNA_MOCK_STDERR")
    if forced:
        sys.stderr.write(forced)

    if os.environ.get("LUNA_MOCK_EMPTY") == "1" or hungup:
        return int(os.environ.get("LUNA_MOCK_STATUS", "0"))

    joined = " ".join(argv)
    if "getSystemInfo" in joined:
        if os.environ.get("LUNA_MOCK_FORMAT") == "compact":
            sys.stdout.write('{ "returnValue": true, "sdkVersion": "3.4.0" }\n')
        else:
            sys.stdout.write('{\n    "sdkVersion": "3.4.0"\n}\n')
    elif "addMvpd" in joined or "removeMvpd" in joined:
        sys.stdout.write('{"returnValue":true}\n')
    else:
        sys.stdout.write("{}\n")
    return int(os.environ.get("LUNA_MOCK_STATUS", "0"))


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Resident set growth and request latency of the language server.

Usage: scripts/benchmark-lsp-resident-set.py [--rounds N] [--reps N] LABEL=LSP_BINARY:STDLIB_DIR ...

Each LABEL=BINARY:STDLIB pair is one build under test. Every build runs the same two measurements
on its own standard library.

Growth. The server opens a generated document of 300 words and about 10 KB, then takes N rounds of
one didChange and one hover. Each round renames the last word, so every round interns a new name.
The process is sampled at the start and every N/5 rounds. Resident set size comes from ps.
Physical footprint comes from vmmap on macOS and equals the resident set size on Linux. Physical
footprint is the better figure on macOS, because the allocator advises MADV_FREE_REUSABLE and the
pages stay counted in the resident set until the system wants them back.

Latency. For a plain document, a document with stdlib imports, and a document with an unclosed
bracket mid-document, the driver times each didChange until its publishDiagnostics arrives, and each
hover until its reply arrives. It prints the median, minimum, and maximum over the reps, and the
diagnostics the last didChange published.

The server does not set a version on publishDiagnostics, so the driver cannot match a publish to its
change. It relies on the server handling messages in order. Each hover is sent after its change's
publish arrives, and a second publish that arrives before the hover reply fails the run. A server
that never publishes or never replies fails the run after the read timeout.

Run from the repository root. Build the servers with `make release` for representative numbers.
"""

import argparse
import json
import os
import re
import select
import statistics
import subprocess
import sys
import time

WORDS = 300
IMPORTS = ['use "strings" ;', 'use "sequences" ;', 'use "sets" ;', 'use "text" ;']
READ_TIMEOUT = 30.0


def make_text(rep, imports, broken):
    lines = list(IMPORTS) if imports else []

    for i in range(WORDS):
        if broken and i == WORDS // 2:
            lines.append("broken: ( n -- n ) [ 1 +")

        if i == WORDS - 1:
            lines.append("edit-%04d: ( n -- n ) [ %04d + ] ;" % (rep, rep))
        else:
            lines.append("word-%03d: ( n -- n ) [ %04d + ] ;" % (i, i))

    return "\n".join(lines) + "\n"


def hover_line(text, name):
    for number, line in enumerate(text.split("\n")):
        if line.startswith(name + ":"):
            return number

    raise SystemExit("no line defines " + name)


class Server:
    def __init__(self, binary, stdlib):
        env = dict(os.environ, ONEZ_STDLIB=stdlib)
        self.proc = subprocess.Popen(
            [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, bufsize=0
        )
        self.next_id = 1
        self.buffer = bytearray()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.kill()

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()

        self.proc.wait()

    def send(self, message):
        body = json.dumps(message).encode()
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)

    def fill(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([self.proc.stdout], [], [], remaining)[0]:
            raise SystemExit("no message from the server within %.0f seconds" % READ_TIMEOUT)

        chunk = os.read(self.proc.stdout.fileno(), 65536)
        if not chunk:
            raise SystemExit("server closed its output")

        self.buffer += chunk

    def read(self, deadline):
        while b"\r\n\r\n" not in self.buffer:
            self.fill(deadline)

        head, _, _ = self.buffer.partition(b"\r\n\r\n")
        match = re.search(rb"content-length:\s*(\d+)", head, re.I)
        if not match:
            raise SystemExit("message without a Content-Length header")

        start = len(head) + 4
        end = start + int(match.group(1))
        while len(self.buffer) < end:
            self.fill(deadline)

        message = json.loads(self.buffer[start:end])
        del self.buffer[:end]
        return message

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method, params, uri=None):
        """Sends a request and returns its reply. A publish for `uri` before the reply fails the run."""
        ident = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        deadline = time.monotonic() + READ_TIMEOUT

        while True:
            message = self.read(deadline)

            if "method" not in message and message.get("id") == ident:
                return message

            if uri is not None and is_publish(message, uri):
                raise SystemExit("a second publishDiagnostics arrived for one change")

    def wait_diagnostics(self, uri):
        deadline = time.monotonic() + READ_TIMEOUT

        while True:
            message = self.read(deadline)
            if is_publish(message, uri):
                return message["params"]["diagnostics"]

    def start(self):
        self.request("initialize", {"capabilities": {}})
        self.notify("initialized", {})

    def open(self, uri, text):
        self.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": uri, "languageId": "1z", "version": 1, "text": text}},
        )
        return self.wait_diagnostics(uri)

    def change(self, uri, version, text):
        self.notify(
            "textDocument/didChange",
            {"textDocument": {"uri": uri, "version": version}, "contentChanges": [{"text": text}]},
        )
        return self.wait_diagnostics(uri)

    def hover(self, uri, line):
        reply = self.request(
            "textDocument/hover",
            {"textDocument": {"uri": uri}, "position": {"line": line, "character": 2}},
            uri,
        )
        if "error" in reply:
            raise SystemExit("hover failed: %r" % reply["error"])

    def stop(self):
        self.request("shutdown", None)
        self.notify("exit", None)

        try:
            self.proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.kill()
            raise SystemExit("server did not exit after shutdown")


def is_publish(message, uri):
    return message.get("method") == "textDocument/publishDiagnostics" and message["params"]["uri"] == uri


def to_kib(value):
    match = re.fullmatch(r"([0-9.]+)([KMG]?)", value)
    if not match:
        raise SystemExit("unexpected vmmap size %r" % value)

    number, unit = match.groups()
    scale = {"": 1 / 1024, "K": 1, "M": 1024, "G": 1048576}[unit]
    return int(float(number) * scale)


def sample(pid):
    rss = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)]).strip())

    if sys.platform != "darwin":
        return rss, rss

    summary = subprocess.check_output(["vmmap", "-summary", str(pid)], stderr=subprocess.DEVNULL).decode()
    match = re.search(r"^Physical footprint:\s+(\S+)", summary, re.M)
    if not match:
        raise SystemExit("could not read the physical footprint of %d" % pid)

    return rss, to_kib(match.group(1))


def growth(binary, stdlib, rounds):
    with Server(binary, stdlib) as server:
        server.start()

        uri = "file:///growth.1z"
        text = make_text(0, False, False)
        server.open(uri, text)
        line = hover_line(text, "word-150")

        step = rounds // 5
        rows = [(0,) + sample(server.proc.pid)]

        for round_number in range(1, rounds + 1):
            server.change(uri, round_number + 1, make_text(round_number, False, False))
            server.hover(uri, line)

            if round_number % step == 0:
                rows.append((round_number,) + sample(server.proc.pid))

        server.stop()
        return rows


def latency(binary, stdlib, imports, broken, reps):
    with Server(binary, stdlib) as server:
        server.start()

        uri = "file:///latency.1z"
        text = make_text(0, imports, broken)
        server.open(uri, text)
        line = hover_line(text, "word-150")

        changes = []
        hovers = []
        published = []

        for rep in range(1, reps + 3):
            text = make_text(rep, imports, broken)

            started = time.perf_counter()
            published = server.change(uri, rep + 1, text)
            changed = time.perf_counter()
            server.hover(uri, line)
            hovered = time.perf_counter()

            if rep > 2:
                changes.append((changed - started) * 1000)
                hovers.append((hovered - changed) * 1000)

        server.stop()
        return changes, hovers, published


def summary(samples):
    return "median=%.2f min=%.2f max=%.2f" % (statistics.median(samples), min(samples), max(samples))


def describe(published):
    if not published:
        return "no diagnostics"

    return "%d diagnostics, first: severity %s, %r" % (
        len(published),
        published[0].get("severity"),
        published[0].get("message"),
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rounds", type=int, default=500)
    parser.add_argument("--reps", type=int, default=25)
    parser.add_argument("builds", nargs="+", metavar="LABEL=LSP_BINARY:STDLIB_DIR")
    args = parser.parse_args()

    if args.rounds % 5:
        raise SystemExit("--rounds must be a multiple of 5")

    for spec in args.builds:
        label, rest = spec.split("=", 1)
        binary, stdlib = rest.rsplit(":", 1)

        print("== %s" % label)
        print("growth, %d rounds of one didChange and one hover (KiB)" % args.rounds)
        print("%8s %12s %12s" % ("round", "rss", "footprint"))
        for round_number, rss, footprint in growth(binary, stdlib, args.rounds):
            print("%8d %12d %12d" % (round_number, rss, footprint))

        print("latency over %d reps (ms)" % args.reps)
        for name, imports, broken in (("plain", False, False), ("imports", True, False), ("parse-error", False, True)):
            changes, hovers, published = latency(binary, stdlib, imports, broken, args.reps)
            print("%-12s didChange->diagnostics %s" % (name, summary(changes)))
            print("%-12s hover                  %s" % (name, summary(hovers)))
            print("%-12s published: %s" % (name, describe(published)))

        print()


main()

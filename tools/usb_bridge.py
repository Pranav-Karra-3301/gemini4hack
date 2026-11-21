#!/usr/bin/env python3
"""USB cable link: lets CoachCam on a cabled iPhone reach Coach Core on this Mac.

usbmuxd only lets the Mac open TCP connections to a port on the phone, so this is a reverse
tunnel. CoachCam (CoachKit `USBUplink`) listens on the phone's port 2347; this bridge keeps a pool
of idle connections into it through /var/run/usbmuxd. When the app needs one, it claims it and
the bridge splices it to Core (127.0.0.1:8787). Core sees loopback, so no token is needed.

Uplink protocol, idle phase (one byte each; after 'A' the socket is a raw byte stream):
  bridge -> phone  'K'  keepalive, right after connecting and then every second
  phone  -> bridge 'k'  keepalive (the app is alive and reading)
  phone  -> bridge 'G'  claim: the app has a local connection for this uplink
  bridge -> phone  'A'  Core is connected; splicing starts after this byte

Stdlib only. Usage: python3 tools/usb_bridge.py [--pool 4] [--udid UDID] [--core-port 8787] [-v]
                    python3 tools/usb_bridge.py --list
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import plistlib
import socket
import struct
import sys
import time

USBMUXD = "/var/run/usbmuxd"
PHONE_PORT = 2347
KEEPALIVE_S = 1.0  # bridge 'K' interval
STALE_S = 5.0  # drop an idle uplink after this long without a byte from the phone
CHUNK = 256 * 1024

_tag = 0
_state: dict[str, str] = {}
VERBOSE = False


def log(msg: str) -> None:
    print(time.strftime("%H:%M:%S"), "usb:", msg, flush=True)


def set_state(key: str, value: str, msg: str | None = None) -> None:
    """Log one line when `key` changes to a new `value`."""
    if _state.get(key) != value:
        _state[key] = value
        log(msg or f"{key}: {value}")


# usbmuxd framing: 16-byte little-endian header (length incl. header, version 1, message 8 =
# plist, tag), then an XML plist.
class MuxError(Exception):
    def __init__(self, number: int):
        super().__init__({2: "bad device", 3: "connection refused", 6: "bad version"}.get(number, f"result {number}"))
        self.number = number


async def mux_send(w: asyncio.StreamWriter, msg: dict) -> int:
    global _tag
    _tag += 1
    body = plistlib.dumps({"ClientVersionString": "coach-usb-bridge", "ProgName": "coach-usb-bridge",
                           "kLibUSBMuxVersion": 3, **msg})
    w.write(struct.pack("<IIII", 16 + len(body), 1, 8, _tag) + body)
    await w.drain()
    return _tag


async def mux_recv(r: asyncio.StreamReader) -> dict:
    length, _version, _message, _tag_ = struct.unpack("<IIII", await r.readexactly(16))
    return plistlib.loads(await r.readexactly(length - 16))


async def mux_request(msg: dict) -> tuple[asyncio.StreamReader, asyncio.StreamWriter, dict]:
    r, w = await asyncio.open_unix_connection(USBMUXD)
    try:
        await mux_send(w, msg)
        return r, w, await mux_recv(r)
    except BaseException:
        w.close()
        raise


async def list_devices() -> list[dict]:
    _r, w, reply = await mux_request({"MessageType": "ListDevices"})
    w.close()
    return reply.get("DeviceList", [])


async def mux_connect(device_id: int, port: int) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    """A TCP connection to `port` on the phone, through usbmuxd (port goes in network byte order)."""
    r, w, reply = await mux_request({"MessageType": "Connect", "DeviceID": device_id,
                                     "PortNumber": socket.htons(port)})
    if reply.get("MessageType") != "Result" or reply.get("Number", -1) != 0:
        w.close()
        raise MuxError(reply.get("Number", -1))
    return r, w


def close(w: asyncio.StreamWriter | None) -> None:
    if w is not None:
        with contextlib.suppress(Exception):
            w.close()


class DevicePool:
    """Keeps `size` idle uplinks open into one phone and splices claimed ones to Core."""

    def __init__(self, device_id: int, udid: str, args: argparse.Namespace):
        self.id, self.udid, self.args = device_id, udid, args
        self.app_open = asyncio.Event()  # while clear, only slot 0 probes the phone
        self.sessions = 0
        self.active = 0
        self.tasks: list[asyncio.Task] = []
        self.splices: set[asyncio.Task] = set()

    def start(self) -> None:
        self.tasks = [asyncio.create_task(self.slot(i)) for i in range(self.args.pool)]

    def stop(self) -> None:
        for t in self.tasks:
            t.cancel()
        _state.pop(f"link:{self.udid}", None)

    def link(self, state: str) -> None:
        set_state(f"link:{self.udid}", state, {
            "up": f"linked: CoachCam on {self.udid} is answering (pool {self.args.pool})",
            "closed": f"waiting for CoachCam on {self.udid}: nothing on port {PHONE_PORT} (app not running)",
            "silent": f"CoachCam on {self.udid} accepted but went quiet (suspended in the background?)",
        }[state])

    async def slot(self, i: int) -> None:
        backoff = 0.25
        while True:
            if i > 0:
                await self.app_open.wait()
            w, outcome = None, "error"
            try:
                r, w = await mux_connect(self.id, PHONE_PORT)
                outcome = await self.idle_phase(r, w)
            except MuxError as e:
                outcome = "refused" if e.number == 3 else "gone"
            except (OSError, asyncio.IncompleteReadError):
                pass
            if outcome == "claimed":
                t = asyncio.create_task(self.splice(r, w))
                self.splices.add(t)
                t.add_done_callback(self.splices.discard)
                backoff = 0.25
                continue  # refill right away
            close(w)
            if outcome == "gone":
                return  # device detached; the Listen loop logs it
            if outcome in ("refused", "stale"):
                self.app_open.clear()
                self.link("closed" if outcome == "refused" else "silent")
            elif outcome == "closed":
                backoff = 0.1  # the app dropped it (restart or stale); try again soon
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 1.0)

    async def idle_phase(self, r: asyncio.StreamReader, w: asyncio.StreamWriter) -> str:
        w.write(b"K")
        await w.drain()
        now = time.monotonic()
        next_k, heard = now + KEEPALIVE_S, now
        while True:
            try:
                data = await asyncio.wait_for(r.read(64), timeout=max(0.0, next_k - time.monotonic()))
            except (asyncio.TimeoutError, TimeoutError):
                if time.monotonic() - heard > STALE_S:
                    return "stale"
                w.write(b"K")
                await w.drain()
                next_k = time.monotonic() + KEEPALIVE_S
                continue
            if not data:
                return "closed"
            heard = time.monotonic()
            if not self.app_open.is_set():
                self.app_open.set()
                self.link("up")
            if b"G" in data:
                return "claimed"

    async def splice(self, r: asyncio.StreamReader, w: asyncio.StreamWriter) -> None:
        self.sessions += 1
        n, t0 = self.sessions, time.monotonic()
        try:
            cr, cw = await asyncio.wait_for(asyncio.open_connection(self.args.core_host, self.args.core_port), 3)
        except (OSError, asyncio.TimeoutError, TimeoutError) as e:
            set_state("core", "down", f"Core unreachable at {self.args.core_host}:{self.args.core_port} ({e or type(e).__name__})")
            close(w)
            return
        set_state("core", "up", f"Core reachable at {self.args.core_host}:{self.args.core_port}")
        self.active += 1
        counts = [0, 0]

        async def pump(src: asyncio.StreamReader, dst: asyncio.StreamWriter, k: int) -> None:
            try:
                while data := await src.read(CHUNK):
                    counts[k] += len(data)
                    dst.write(data)
                    await dst.drain()
                if dst.can_write_eof():
                    dst.write_eof()  # half-close: pass the FIN along
            except (OSError, RuntimeError):
                close(w)
                close(cw)

        try:
            w.write(b"A")
            await w.drain()
            if VERBOSE:
                log(f"session {n} open ({self.active} active)")
            await asyncio.gather(pump(r, cw, 0), pump(cr, w, 1))
        except OSError:
            pass
        finally:
            close(w)
            close(cw)
            self.active -= 1
            if VERBOSE:
                log(f"session {n} closed: {counts[0]} B up, {counts[1]} B down, {time.monotonic() - t0:.2f} s")


async def run(args: argparse.Namespace) -> None:
    pools: dict[int, DevicePool] = {}
    log(f"bridge: phone port {PHONE_PORT} -> {args.core_host}:{args.core_port}, pool {args.pool}"
        + (f", udid {args.udid}" if args.udid else ""))
    while True:
        w = None
        try:
            r, w, reply = await mux_request({"MessageType": "Listen"})
            if reply.get("Number", -1) != 0:
                raise MuxError(reply.get("Number", -1))
            set_state("usbmuxd", "up", "usbmuxd: listening for devices")
            while True:
                msg = await mux_recv(r)
                kind, dev_id = msg.get("MessageType"), msg.get("DeviceID")
                props = msg.get("Properties", {})
                if kind == "Attached":
                    udid = props.get("SerialNumber", "?")
                    if props.get("ConnectionType") != "USB" or (args.udid and udid.replace("-", "") != args.udid.replace("-", "")):
                        continue
                    if dev_id not in pools:
                        log(f"device attached: {udid} (id {dev_id}, USB)")
                        pools[dev_id] = DevicePool(dev_id, udid, args)
                        pools[dev_id].start()
                elif kind == "Detached" and dev_id in pools:
                    log(f"device detached: {pools[dev_id].udid} (id {dev_id})")
                    pools.pop(dev_id).stop()
        except (OSError, asyncio.IncompleteReadError, MuxError) as e:
            set_state("usbmuxd", "down", f"usbmuxd: lost ({e or type(e).__name__}); retrying")
        finally:
            close(w)
        for p in pools.values():
            p.stop()
        pools.clear()
        await asyncio.sleep(1)


def main() -> None:
    global VERBOSE
    ap = argparse.ArgumentParser(description="USB reverse tunnel from CoachCam (iPhone) to Coach Core.")
    ap.add_argument("--pool", type=int, default=4, help="idle uplinks to keep open (default 4)")
    ap.add_argument("--udid", help="only this device (default: every USB-attached device)")
    ap.add_argument("--core-host", default="127.0.0.1")
    ap.add_argument("--core-port", type=int, default=8787)
    ap.add_argument("--list", action="store_true", help="list usbmuxd devices and exit")
    ap.add_argument("-v", "--verbose", action="store_true", help="also log each spliced session")
    args = ap.parse_args()
    VERBOSE = args.verbose
    if args.list:
        for d in asyncio.run(list_devices()):
            p = d.get("Properties", {})
            print(d.get("DeviceID"), p.get("SerialNumber"), p.get("ConnectionType"), p.get("ProductID", ""))
        return
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())

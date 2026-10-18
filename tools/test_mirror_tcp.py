#!/usr/bin/env python3
"""
Test tool and client for MiniScheme ESP32 TCP Mirror Streaming Protocol (T2/T3).

Usage:
    python test_mirror_tcp.py [host] [port] [password]

Default target: 127.0.0.1:8088
"""

import sys
import socket
import struct
import time
import argparse


class TcpMirrorClient:
    def __init__(self, host="127.0.0.1", port=8088, password=""):
        self.host = host
        self.port = port
        self.password = password
        self.sock = None

    def connect(self, timeout=3.0):
        self.sock = socket.create_connection((self.host, self.port), timeout=timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def authenticate(self, custom_password=None, since=0):
        pwd = self.password if custom_password is None else custom_password
        auth_line = f"AUTH {pwd}"
        if since > 0:
            auth_line += f" since={since}"
        auth_line += "\r\n"
        self.sock.sendall(auth_line.encode("utf-8"))

        # Read response line
        resp = b""
        while b"\n" not in resp:
            chunk = self.sock.recv(64)
            if not chunk:
                break
            resp += chunk

        resp_str = resp.decode("utf-8", errors="replace").strip()
        return resp_str

    def send_command(self, cmd):
        if not self.sock:
            raise RuntimeError("Not connected")
        self.sock.sendall(f"{cmd}\r\n".encode("utf-8"))

    def read_exact(self, n):
        data = bytearray()
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionResetError("Connection closed while reading frame")
            data.extend(chunk)
        return bytes(data)

    def read_frame(self, timeout=5.0):
        self.sock.settimeout(timeout)
        # 1. Read 4 bytes length header (little-endian uint32)
        len_bytes = self.read_exact(4)
        (length,) = struct.unpack("<I", len_bytes)
        if length < 16 or length > 65536:
            raise ValueError(f"Invalid frame length: {length}")

        # 2. Read payload
        payload = self.read_exact(length)

        # 3. Parse MSCR header
        magic = payload[:4]
        if magic != b"MSCR":
            raise ValueError(f"Invalid frame magic: {magic}")

        version = payload[4]
        flags = payload[5]
        width, height, nrows, clock = struct.unpack("<HHHI", payload[6:16])

        # Parse dirty rows
        rows = []
        at = 16
        for _ in range(nrows):
            if at + 4 > len(payload):
                break
            y, nbytes = struct.unpack("<HH", payload[at:at + 4])
            at += 4
            packbits_data = payload[at:at + nbytes]
            at += nbytes
            rows.append({"y": y, "bytes": nbytes, "data": packbits_data})

        return {
            "version": version,
            "flags": flags,
            "more": bool(flags & 1),
            "nopixels": bool(flags & 2),
            "width": width,
            "height": height,
            "nrows": nrows,
            "clock": clock,
            "raw_len": length + 4,
            "rows": rows,
        }

    def close(self):
        if self.sock:
            try:
                self.send_command("QUIT")
            except Exception:
                pass
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None


def run_benchmark(host, port, password, duration_sec=5):
    print(f"Connecting to TCP Mirror Server at {host}:{port}...")
    client = TcpMirrorClient(host, port, password)
    try:
        client.connect()
        auth_resp = client.authenticate()
        print(f"Auth response: {auth_resp}")
        if not auth_resp.startswith("+OK") and not auth_resp.startswith("OK"):
            print("Authentication failed!")
            return False

        print(f"Streaming screen frames for {duration_sec} seconds (T2 persistent streaming)...")
        start_time = time.time()
        frame_count = 0
        total_bytes = 0
        total_rows = 0

        while time.time() - start_time < duration_sec:
            try:
                frame = client.read_frame(timeout=2.0)
                frame_count += 1
                total_bytes += frame["raw_len"]
                total_rows += frame["nrows"]
                if frame_count <= 3 or frame_count % 10 == 0:
                    print(f"  Frame #{frame_count:03d}: {frame['width']}x{frame['height']}, "
                          f"dirty_rows={frame['nrows']}, clock={frame['clock']}, "
                          f"bytes={frame['raw_len']}, more={frame['more']}")
            except socket.timeout:
                # Still screen sends no bytes
                print("  [Idle: screen unchanged, 0 bytes transmitted]")

        elapsed = time.time() - start_time
        fps = frame_count / elapsed if elapsed > 0 else 0
        kbps = (total_bytes / 1024) / elapsed if elapsed > 0 else 0

        print("\n--- Benchmark Results ---")
        print(f"Elapsed Time:  {elapsed:.2f} s")
        print(f"Total Frames:  {frame_count}")
        print(f"Average FPS:   {fps:.2f} FPS")
        print(f"Total Traffic: {total_bytes / 1024:.2f} KB ({kbps:.2f} KB/s)")
        print(f"Total Rows:    {total_rows} dirty rows rendered")
        print("-------------------------\n")
        return True
    finally:
        client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Test MiniScheme TCP Mirror Stream")
    parser.add_argument("host", nargs="?", default="127.0.0.1", help="Device IP or host")
    parser.add_argument("port", nargs="?", type=int, default=8088, help="TCP mirror port")
    parser.add_argument("password", nargs="?", default="", help="Device password")
    parser.add_argument("--duration", type=int, default=5, help="Benchmark duration in seconds")
    args = parser.parse_args()

    run_benchmark(args.host, args.port, args.password, args.duration)

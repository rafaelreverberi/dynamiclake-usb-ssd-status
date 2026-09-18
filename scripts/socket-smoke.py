#!/usr/bin/env python3
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def read_exact(connection: socket.socket, count: int) -> bytes:
    data = bytearray()
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        if not chunk:
            raise RuntimeError("plugin closed the socket")
        data.extend(chunk)
    return bytes(data)


def read_frame(connection: socket.socket) -> dict:
    size = struct.unpack(">I", read_exact(connection, 4))[0]
    return json.loads(read_exact(connection, size))


def send_frame(connection: socket.socket, value: dict) -> None:
    payload = json.dumps(value, separators=(",", ":")).encode()
    connection.sendall(struct.pack(">I", len(payload)) + payload)


def main() -> int:
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/transfer-center").resolve()
    if not binary.is_file():
        raise SystemExit(f"missing binary: {binary}")
    with tempfile.TemporaryDirectory(prefix="transfer-center-smoke-") as directory:
        path = str(Path(directory) / "dynamiclake.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        server.settimeout(5)
        environment = os.environ.copy()
        environment["DYNAMICLAKE_JSON_SOCKET"] = path
        environment["DYNAMICLAKE_PLUGIN_FEATURES"] = "presentSneakPeek"
        process = subprocess.Popen([str(binary), "--mock-transfer"], env=environment)
        try:
            connection, _ = server.accept()
            connection.settimeout(5)
            first = read_frame(connection)
            assert first["type"] == "create"
            assert first["activityID"] == "transfer-center.active"
            assert "compactLiveActivity" in first["surfaces"]
            send_frame(connection, {"type": "response", "ok": True, "requestID": first.get("requestID")})
            completion = None
            for _ in range(12):
                frame = read_frame(connection)
                assert frame["type"] == "update"
                send_frame(connection, {"type": "response", "ok": True, "requestID": frame.get("requestID")})
                if frame.get("presentSneakPeek") == 2:
                    completion = frame
                    break
            assert completion is not None, "completion update with presentSneakPeek was not received"
            print("Socket smoke test passed: create and completion update frames decoded.")
            connection.close()
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
            server.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

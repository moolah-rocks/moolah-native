#!/usr/bin/env python3
"""Exercise the real localhost listener using the official Python MCP client.

Run with mcp==2.3.0 in an isolated environment. The fixture receives an ephemeral
secret over stdin; it has no connection to the app, Keychain, or financial data.
"""
import asyncio
import os
from pathlib import Path
import secrets
import selectors
import socket
import subprocess
import sys

import httpx2 as httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


async def verify(binary):
    token = secrets.token_urlsafe(32)
    # Each isolated fixture is explicitly configured with its own port.
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    log_path = Path(".agent-tmp/mcp-transport-fixture.txt")
    with log_path.open("w") as log:
        process = subprocess.Popen(
            [binary, str(port)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=log, text=True,
        )
        try:
            process.stdin.write(token + "\n")
            process.stdin.close()
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                assert selector.select(timeout=30), f"Listener did not become ready; see {log_path}"
                assert process.stdout.readline().startswith("READY "), f"Listener failed; see {log_path}"
            endpoint = f"http://127.0.0.1:{port}/mcp"
            auth = {"Authorization": "Bearer " + token}
            listening = subprocess.check_output([
                "lsof", "-nP", "-a", "-p", str(process.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"
            ], text=True)
            assert [line for line in listening.splitlines() if line.startswith("n")] == [
                f"n127.0.0.1:{port}"
            ], listening
            with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
                raw.sendall((
                    "POST http://evil.test/mcp HTTP/1.1\r\n"
                    f"Host: 127.0.0.1:{port}\r\n"
                    "Authorization: Bearer " + token + "\r\n"
                    "Content-Length: 0\r\n\r\n"
                ).encode())
                assert raw.recv(1024) == b"", "Absolute-form request target was accepted"
            async with httpx.AsyncClient(timeout=20, trust_env=False) as client:
                for headers in ({}, {"Authorization": "Bearer invalid"}):
                    response = await client.get(endpoint, headers=headers)
                    assert response.status_code == 401, response.status_code
                response = await client.get(endpoint, headers=auth)
                assert response.status_code == 405, response.status_code
                for extra in ({"Host": "evil.test"}, {"Origin": "https://evil.test"}):
                    response = await client.post(endpoint, headers=auth | extra, json={})
                    assert response.status_code == 403, response.status_code
                response = await client.post(endpoint, headers=auth, content=b"x" * 1_048_577)
                assert response.status_code == 413, response.status_code
            async with httpx.AsyncClient(headers=auth, timeout=20, trust_env=False) as transport_client, streamable_http_client(
                endpoint, http_client=transport_client
            ) as (read, write):
                async with ClientSession(read, write) as session:
                    initialized = await session.initialize()
                    assert initialized.protocol_version == "2025-11-25", initialized.protocol_version
                    tools = await session.list_tools()
                    assert [tool.name for tool in tools.tools] == ["moolah_transport_probe"]
                    result = await session.call_tool("moolah_transport_probe", {})
                    assert result.structured_content == {"ready": True}
                    assert not result.is_error
            print("PASS: reference-client handshake/list/call, bearer, Host, Origin, methods, body cap, raw target, loopback bind")
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    asyncio.run(verify(os.path.abspath(sys.argv[1])))

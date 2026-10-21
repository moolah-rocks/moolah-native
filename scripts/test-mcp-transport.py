#!/usr/bin/env python3
"""Exercise the real localhost listener using the official Python MCP client.

Run with mcp==2.3.0 in an isolated environment. The fixture returns its generated
credential over a private pipe, never logs. It has no app, Keychain or financial data.
"""
import asyncio
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import sys

import httpx2 as httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


async def verify(binary, inspector=None):
    # Each isolated fixture is explicitly configured with its own port.
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    log_path = Path(".agent-tmp/mcp-transport-fixture.txt")
    read_fd, write_fd = os.pipe()
    with log_path.open("w") as log, os.fdopen(read_fd) as credentials:
        try:
            process = subprocess.Popen(
                [binary, str(port), str(write_fd)], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=log, text=True, pass_fds=(write_fd,),
            )
        finally:
            os.close(write_fd)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(credentials, selectors.EVENT_READ)
                assert selector.select(timeout=30), f"Credential pipe failed; see {log_path}"
                token = credentials.readline().strip()
                assert token.startswith("moolah_"), f"Fixture startup failed; see {log_path}"
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
            if inspector:
                config = json.dumps({"mcpServers": {"fixture": {
                    "type": "http", "url": endpoint, "headers": auth,
                }}})
                for method in ("tools/list", "tools/call"):
                    command = [inspector, "--cli", "--config", "/dev/stdin",
                               "--server", "fixture", "--method", method]
                    if method == "tools/call":
                        command += ["--tool-name", "moolah_transport_probe"]
                    checked = await asyncio.to_thread(
                        subprocess.run, command, input=config, text=True,
                        capture_output=True, timeout=30,
                    )
                    # Never print subprocess output: clients may echo configuration.
                    assert checked.returncode == 0, "Inspector fixture check failed"
                    response = json.loads(checked.stdout)
                    if method == "tools/list":
                        assert [tool["name"] for tool in response["tools"]] == ["moolah_transport_probe"]
                    else:
                        assert response["structuredContent"] == {"ready": True}
                        assert not response.get("isError", False)
                print("PASS: MCP Inspector 2.11.0 authenticated discovery and structured call")
            async with httpx.AsyncClient(timeout=20, trust_env=False) as client:
                for _ in range(61):
                    response = await client.post(endpoint, headers=auth | {
                        "Content-Type": "application/json", "Accept": "application/json",
                        "MCP-Protocol-Version": "2025-11-25",
                    }, json={"jsonrpc": "2.0", "id": 1, "method": "ping"})
                    if response.status_code == 429:
                        assert response.headers.get("Retry-After") == "60"
                        break
                    assert response.status_code == 200, response.status_code
                else:
                    raise AssertionError("Authenticated request rate was not bounded")
            log.flush()
            logged = log_path.read_text()
            assert token not in logged, "Fixture logged its credential"
            assert "Transport probe succeeded" not in logged, "Fixture logged a tool payload"
            print("PASS: reference-client handshake/list/call, bearer, Host, Origin, methods, body cap, raw target, loopback bind, production grant validation and rate limit")
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    asyncio.run(verify(os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else None))

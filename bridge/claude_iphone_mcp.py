"""
ClaudeFileServer MCP Bridge — Gives Claude Code native tools to access iPhone files.

Environment variables:
    IPHONE_HOST  — iPhone IP address
    IPHONE_PORT  — Server port (default: 8080)
    IPHONE_TOKEN — Auth token from the iOS app

Install: pip install mcp httpx
Run: python claude_iphone_mcp.py
"""

import os
import json
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP

# Configuration from environment
HOST = os.environ.get("IPHONE_HOST", "")
PORT = os.environ.get("IPHONE_PORT", "8080")
TOKEN = os.environ.get("IPHONE_TOKEN", "")

mcp = FastMCP("iphone-file-server")


def _base_url() -> str:
    if not HOST:
        raise RuntimeError("IPHONE_HOST not set")
    return f"http://{HOST}:{PORT}/api"


def _headers() -> dict[str, str]:
    if not TOKEN:
        raise RuntimeError("IPHONE_TOKEN not set")
    return {"Authorization": f"Bearer {TOKEN}"}


def _get(endpoint: str, params: dict[str, str] | None = None) -> dict[str, Any]:
    with httpx.Client(timeout=30) as client:
        resp = client.get(f"{_base_url()}/{endpoint}", params=params, headers=_headers())
        resp.raise_for_status()
        return resp.json()


def _post(endpoint: str, body: dict[str, Any]) -> dict[str, Any]:
    with httpx.Client(timeout=30) as client:
        resp = client.post(f"{_base_url()}/{endpoint}", json=body, headers=_headers())
        resp.raise_for_status()
        return resp.json()


def _delete(endpoint: str, params: dict[str, str]) -> dict[str, Any]:
    with httpx.Client(timeout=30) as client:
        resp = client.delete(f"{_base_url()}/{endpoint}", params=params, headers=_headers())
        resp.raise_for_status()
        return resp.json()


@mcp.tool()
def iphone_info() -> str:
    """Get device info and list of accessible paths on the connected iPhone."""
    result = _get("info")
    return json.dumps(result, indent=2)


@mcp.tool()
def iphone_ls(path: str) -> str:
    """List directory contents on the iPhone.

    Args:
        path: Absolute path to the directory to list.
    """
    result = _get("ls", {"path": path})
    return json.dumps(result, indent=2)


@mcp.tool()
def iphone_read(path: str) -> str:
    """Read a file from the iPhone. Returns content as UTF-8 text or base64.

    Args:
        path: Absolute path to the file to read.
    """
    result = _get("read", {"path": path})
    return json.dumps(result, indent=2)


@mcp.tool()
def iphone_write(path: str, content: str, encoding: str = "utf-8") -> str:
    """Write content to a file on the iPhone.

    Args:
        path: Absolute path to the file to write.
        content: The content to write (UTF-8 string or base64-encoded).
        encoding: Either "utf-8" (default) or "base64".
    """
    result = _post("write", {"path": path, "content": content, "encoding": encoding})
    return json.dumps(result, indent=2)


@mcp.tool()
def iphone_delete(path: str) -> str:
    """Delete a file or directory on the iPhone.

    Args:
        path: Absolute path to the file or directory to delete.
    """
    result = _delete("delete", {"path": path})
    return json.dumps(result, indent=2)


@mcp.tool()
def iphone_mkdir(path: str) -> str:
    """Create a directory on the iPhone (with intermediate directories).

    Args:
        path: Absolute path to the directory to create.
    """
    result = _post("mkdir", {"path": path})
    return json.dumps(result, indent=2)


if __name__ == "__main__":
    mcp.run()

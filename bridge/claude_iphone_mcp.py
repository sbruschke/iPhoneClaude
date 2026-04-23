"""
ClaudeFileServer MCP Bridge — Gives Claude Code native tools to access iPhone files.

Environment variables:
    IPHONE_HOST  — iPhone IP address
    IPHONE_PORT  — Server port (default: 8080)
    IPHONE_TOKEN — Auth token from the iOS app

Install: pip install -r requirements.txt
Run: python claude_iphone_mcp.py
"""

import base64
import hashlib
import json
import os
import tempfile
import time
import zipfile
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP

HOST = os.environ.get("IPHONE_HOST", "")
PORT = os.environ.get("IPHONE_PORT", "8080")
TOKEN = os.environ.get("IPHONE_TOKEN", "")

mcp = FastMCP("iphone-file-server")


def _base_url() -> str:
    if not HOST:
        raise RuntimeError("IPHONE_HOST not set")
    return f"http://{HOST}:{PORT}/api"


def _auth_headers() -> dict[str, str]:
    if not TOKEN:
        raise RuntimeError("IPHONE_TOKEN not set")
    return {"Authorization": f"Bearer {TOKEN}"}


# Shared client: one TCP connection pool reused across all calls. The phone's
# WiFi radio sleeps between packets, so the per-call handshake is the dominant
# cost in multi-file workflows. Keep-alive + HTTP/2 (falls back to 1.1 on this
# server) plus gzip collapses that overhead.
def _new_client() -> httpx.Client:
    return httpx.Client(
        http2=True,
        timeout=httpx.Timeout(300.0, connect=10.0),
        headers={"Accept-Encoding": "gzip"},
    )


_client = _new_client()

# GCDWebServer sometimes closes idle keep-alive sockets between requests,
# which surfaces as ReadError/RemoteProtocolError on the next send. One
# retry on a fresh connection clears it.
_RETRYABLE = (httpx.RemoteProtocolError, httpx.ReadError, httpx.ConnectError)


def _send(method: str, endpoint: str, **kwargs: Any) -> dict[str, Any]:
    global _client
    url = f"{_base_url()}/{endpoint}"
    headers = {**_auth_headers(), **kwargs.pop("headers", {})}
    last_exc: Exception | None = None
    for attempt in range(4):
        try:
            resp = _client.request(method, url, headers=headers, **kwargs)
            resp.raise_for_status()
            return resp.json()
        except _RETRYABLE as exc:
            last_exc = exc
            try:
                _client.close()
            except Exception:
                pass
            _client = _new_client()
            # Small backoff — phone radio may be asleep.
            time.sleep(0.2 * (attempt + 1))
    raise last_exc  # type: ignore[misc]


def _get(endpoint: str, params: dict[str, str] | None = None) -> dict[str, Any]:
    return _send("GET", endpoint, params=params)


def _post(endpoint: str, body: dict[str, Any]) -> dict[str, Any]:
    return _send("POST", endpoint, json=body)


def _delete(endpoint: str, params: dict[str, str]) -> dict[str, Any]:
    return _send("DELETE", endpoint, params=params)


def _put_binary(endpoint: str, path: str, data: bytes) -> dict[str, Any]:
    return _send(
        "PUT",
        endpoint,
        params={"path": path},
        content=data,
        headers={"Content-Type": "application/octet-stream"},
    )


def _post_binary(endpoint: str, params: dict[str, str], data: bytes, content_type: str) -> dict[str, Any]:
    return _send(
        "POST",
        endpoint,
        params=params,
        content=data,
        headers={"Content-Type": content_type},
    )


def _get_bytes(endpoint: str, params: dict[str, str]) -> bytes:
    global _client
    url = f"{_base_url()}/{endpoint}"
    headers = _auth_headers()
    last_exc: Exception | None = None
    for attempt in range(4):
        try:
            resp = _client.get(url, params=params, headers=headers)
            resp.raise_for_status()
            return resp.content
        except _RETRYABLE as exc:
            last_exc = exc
            try:
                _client.close()
            except Exception:
                pass
            _client = _new_client()
            time.sleep(0.2 * (attempt + 1))
    raise last_exc  # type: ignore[misc]


@mcp.tool()
def iphone_info() -> str:
    """Get device info and list of accessible paths on the connected iPhone."""
    return json.dumps(_get("info"), indent=2)


@mcp.tool()
def iphone_ls(path: str) -> str:
    """List directory contents on the iPhone.

    Args:
        path: Absolute path to the directory to list.
    """
    return json.dumps(_get("ls", {"path": path}), indent=2)


@mcp.tool()
def iphone_ls_recursive(path: str, max_depth: int | None = None) -> str:
    """Recursively walk a directory on the iPhone in ONE MCP call.

    Issues /api/ls sequentially for each subdirectory over the shared HTTP
    connection — still N HTTP requests under the hood, but one tool-call and
    one Claude round-trip regardless of tree size.

    Args:
        path: Absolute path to the root directory.
        max_depth: If set, limits recursion depth (root = depth 0).
    """
    tree: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = []
    dir_count = 0

    def walk(current: str, depth: int) -> None:
        nonlocal dir_count
        if max_depth is not None and depth > max_depth:
            return
        try:
            data = _get("ls", {"path": current})
        except Exception as exc:
            errors.append({"path": current, "error": str(exc)})
            return
        dir_count += 1
        for entry in data.get("entries", []):
            tree.append({
                "path": entry["path"],
                "name": entry["name"],
                "isDirectory": entry["isDirectory"],
                "size": entry["size"],
                "modified": entry["modified"],
                "depth": depth + 1,
            })
            if entry["isDirectory"]:
                walk(entry["path"], depth + 1)

    walk(path, 0)
    return json.dumps({
        "root": path,
        "directories_scanned": dir_count,
        "total_entries": len(tree),
        "errors": errors,
        "entries": tree,
    }, indent=2)


@mcp.tool()
def iphone_read(path: str) -> str:
    """Read a file from the iPhone. Returns content as UTF-8 text or base64.

    Args:
        path: Absolute path to the file to read.
    """
    return json.dumps(_get("read", {"path": path}), indent=2)


@mcp.tool()
def iphone_write(path: str, content: str, encoding: str = "utf-8") -> str:
    """Write content to a file on the iPhone.

    Args:
        path: Absolute path to the file to write.
        content: The content to write (UTF-8 string or base64-encoded).
        encoding: Either "utf-8" (default) or "base64".
    """
    return json.dumps(
        _post("write", {"path": path, "content": content, "encoding": encoding}),
        indent=2,
    )


@mcp.tool()
def iphone_upload_binary(local_path: str, remote_path: str) -> str:
    """Upload a local file to the iPhone as raw bytes via PUT /api/upload.

    Avoids base64 overhead for binaries. Parent dirs are created server-side.

    Args:
        local_path: Path to the local file to upload.
        remote_path: Absolute destination path on the iPhone.
    """
    with open(local_path, "rb") as f:
        data = f.read()
    result = _put_binary("upload", remote_path, data)
    return json.dumps(result, indent=2)


@mcp.tool()
def iphone_pull(remote_path: str, local_path: str) -> str:
    """Pull a file from the iPhone to local disk.

    Keeps file content OUT of Claude's context — returns only size and sha256.

    Args:
        remote_path: Absolute path on the iPhone.
        local_path: Destination path on this machine.
    """
    data = _get("read", {"path": remote_path})
    encoding = data.get("encoding", "utf-8")
    content = data.get("content", "")
    if encoding == "base64":
        raw = base64.b64decode(content)
    else:
        raw = content.encode("utf-8")
    os.makedirs(os.path.dirname(os.path.abspath(local_path)) or ".", exist_ok=True)
    with open(local_path, "wb") as f:
        f.write(raw)
    return json.dumps({
        "local_path": os.path.abspath(local_path),
        "bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "encoding": encoding,
    }, indent=2)


@mcp.tool()
def iphone_delete(path: str) -> str:
    """Delete a file or directory on the iPhone.

    Args:
        path: Absolute path to the file or directory to delete.
    """
    return json.dumps(_delete("delete", {"path": path}), indent=2)


@mcp.tool()
def iphone_mkdir(path: str) -> str:
    """Create a directory on the iPhone (with intermediate directories).

    Args:
        path: Absolute path to the directory to create.
    """
    return json.dumps(_post("mkdir", {"path": path}), indent=2)


@mcp.tool()
def iphone_extract_zip(local_zip_path: str, remote_dest: str) -> str:
    """Upload a local zip file and extract it on the iPhone in a single call.

    POSTs the zip bytes to /api/zip_extract. Parent dirs under remote_dest
    are created automatically. Returns {files_extracted, bytes_written}.

    Args:
        local_zip_path: Path to the local .zip file.
        remote_dest: Absolute destination directory on the iPhone.
    """
    with open(local_zip_path, "rb") as f:
        data = f.read()
    result = _post_binary(
        "zip_extract",
        params={"path": remote_dest},
        data=data,
        content_type="application/zip",
    )
    return json.dumps(result, indent=2)


@mcp.tool()
def iphone_create_zip(remote_dir: str, local_zip_path: str) -> str:
    """Zip a remote directory on the iPhone and stream it to local disk.

    Returns only {bytes, sha256, local_path} — zip content stays out of
    Claude's context.

    Args:
        remote_dir: Absolute directory path on the iPhone.
        local_zip_path: Destination path for the downloaded .zip.
    """
    data = _get_bytes("zip_create", {"path": remote_dir})
    os.makedirs(os.path.dirname(os.path.abspath(local_zip_path)) or ".", exist_ok=True)
    with open(local_zip_path, "wb") as f:
        f.write(data)
    return json.dumps({
        "local_path": os.path.abspath(local_zip_path),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }, indent=2)


@mcp.tool()
def iphone_sync(local_dir: str, remote_dir: str) -> str:
    """Zip a local directory, push to the iPhone, extract server-side.

    One MCP call replaces N file ops for tree-style installs (e.g.
    dropping a Controllify mod onto the phone).

    Args:
        local_dir: Local directory whose CONTENTS will be synced.
        remote_dir: Absolute destination directory on the iPhone. Created
                    if missing. Files overwrite on name collision.
    """
    if not os.path.isdir(local_dir):
        raise RuntimeError(f"Not a directory: {local_dir}")

    file_count = 0
    total_bytes = 0
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
            for root, _, files in os.walk(local_dir):
                for name in files:
                    full = os.path.join(root, name)
                    rel = os.path.relpath(full, local_dir)
                    zf.write(full, rel)
                    file_count += 1
                    total_bytes += os.path.getsize(full)
        zip_size = os.path.getsize(tmp_path)
        with open(tmp_path, "rb") as f:
            zip_bytes = f.read()
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass

    result = _post_binary(
        "zip_extract",
        params={"path": remote_dir},
        data=zip_bytes,
        content_type="application/zip",
    )
    return json.dumps({
        "local_dir": os.path.abspath(local_dir),
        "remote_dir": remote_dir,
        "files_zipped": file_count,
        "uncompressed_bytes": total_bytes,
        "zip_bytes": zip_size,
        "server": result,
    }, indent=2)


if __name__ == "__main__":
    mcp.run()

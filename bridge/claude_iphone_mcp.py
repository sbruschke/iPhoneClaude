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


_CONFIG_HINT = (
    "Configure the MCP server in ~/.claude.json under "
    "mcpServers.iphone.env — set IPHONE_HOST (phone's LAN IP) and "
    "IPHONE_TOKEN (token shown in the ClaudeFileServer app). "
    "Run iphone_discover() to find the phone via mDNS."
)


def _base_url() -> str:
    if not HOST:
        raise RuntimeError(f"IPHONE_HOST not set. {_CONFIG_HINT}")
    return f"http://{HOST}:{PORT}/api"


def _auth_headers() -> dict[str, str]:
    if not TOKEN:
        raise RuntimeError(f"IPHONE_TOKEN not set. {_CONFIG_HINT}")
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


def _send(method: str, endpoint: str, *, retry: bool = True, **kwargs: Any) -> dict[str, Any]:
    """Send a request with optional retry on stale keepalive.

    retry=False is mandatory for non-idempotent endpoints (append,
    zip_extract) where a dropped response after server-side success would
    cause a retry to duplicate data. Everything else we expose is
    idempotent: mkdir/write/upload overwrite, DELETE is handled specially
    (404 on retry = previous attempt succeeded).
    """
    global _client
    url = f"{_base_url()}/{endpoint}"
    headers = {**_auth_headers(), **kwargs.pop("headers", {})}
    tries = 4 if retry else 1
    last_exc: Exception | None = None
    for attempt in range(tries):
        try:
            resp = _client.request(method, url, headers=headers, **kwargs)
            if method == "DELETE" and attempt > 0 and resp.status_code == 404:
                return {"success": True, "already_deleted": True,
                        "path": kwargs.get("params", {}).get("path", "")}
            resp.raise_for_status()
            return resp.json()
        except _RETRYABLE as exc:
            last_exc = exc
            try:
                _client.close()
            except Exception:
                pass
            _client = _new_client()
            time.sleep(0.2 * (attempt + 1))
    raise last_exc  # type: ignore[misc]


def _get(endpoint: str, params: dict[str, str] | None = None) -> dict[str, Any]:
    return _send("GET", endpoint, params=params)


def _post(endpoint: str, body: dict[str, Any], *, retry: bool = True) -> dict[str, Any]:
    return _send("POST", endpoint, json=body, retry=retry)


def _delete(endpoint: str, params: dict[str, str]) -> dict[str, Any]:
    return _send("DELETE", endpoint, params=params)


def _put_binary(endpoint: str, path: str, data: bytes, *, retry: bool = True) -> dict[str, Any]:
    return _send(
        "PUT",
        endpoint,
        params={"path": path},
        content=data,
        headers={"Content-Type": "application/octet-stream"},
        retry=retry,
    )


def _post_binary(endpoint: str, params: dict[str, str], data: bytes,
                 content_type: str, *, retry: bool = True) -> dict[str, Any]:
    return _send(
        "POST",
        endpoint,
        params=params,
        content=data,
        headers={"Content-Type": content_type},
        retry=retry,
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
def iphone_ls_recursive(path: str, max_depth: int = 5, max_entries: int = 2000) -> str:
    """Recursively walk a directory on the iPhone in ONE MCP call.

    Issues /api/ls sequentially for each subdirectory over the shared HTTP
    connection — still N HTTP requests under the hood, but one tool-call and
    one Claude round-trip regardless of tree size.

    Args:
        path: Absolute path to the root directory.
        max_depth: Limits recursion depth (root = depth 0). Default 5.
                   Pass a large number for unbounded, but mind context cost.
        max_entries: Hard cap on total entries returned. Extra entries are
                     truncated (reported in `truncated: true`). Default 2000.
    """
    tree: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = []
    dir_count = 0
    truncated = False

    def walk(current: str, depth: int) -> None:
        nonlocal dir_count, truncated
        if depth > max_depth or truncated:
            return
        try:
            data = _get("ls", {"path": current})
        except Exception as exc:
            errors.append({"path": current, "error": str(exc)})
            return
        dir_count += 1
        for entry in data.get("entries", []):
            if len(tree) >= max_entries:
                truncated = True
                return
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
        "truncated": truncated,
        "max_depth": max_depth,
        "max_entries": max_entries,
        "errors": errors,
        "entries": tree,
    }, indent=2)


@mcp.tool()
def iphone_stat(path: str) -> str:
    """Cheap metadata probe — returns {exists, size, modified, isDirectory,
    permissions} WITHOUT reading file content. Use this before iphone_read
    to avoid pulling a huge file into context unintentionally.

    Args:
        path: Absolute path on the iPhone.
    """
    return json.dumps(_get("stat", {"path": path}), indent=2)


@mcp.tool()
def iphone_sha256(path: str) -> str:
    """Server-side SHA-256 of a file. Tiny response (~100 bytes) — use to
    verify sync integrity without pulling content.

    Args:
        path: Absolute path to a file on the iPhone.
    """
    return json.dumps(_get("sha256", {"path": path}), indent=2)


@mcp.tool()
def iphone_view(path: str, head_bytes: int = 4096, tail_bytes: int = 0) -> str:
    """Peek at a file without loading the whole thing into context.

    Streams just the head and/or tail bytes via /api/read_range (raw
    bytes, no JSON base64 wrapping). Decodes as UTF-8 where possible,
    otherwise returns base64.

    Args:
        path: Absolute path to a file on the iPhone.
        head_bytes: Bytes to read from the start. 0 = skip. Default 4096.
        tail_bytes: Bytes to read from the end. 0 = skip. Default 0.
    """
    if head_bytes < 0 or tail_bytes < 0:
        raise RuntimeError("byte counts must be >= 0")
    if head_bytes == 0 and tail_bytes == 0:
        raise RuntimeError("at least one of head_bytes/tail_bytes must be > 0")

    global _client
    out: dict[str, Any] = {"path": path}

    def _range(offset: int, length: int) -> tuple[bytes, dict[str, str]]:
        resp = _client.get(
            f"{_base_url()}/read_range",
            params={"path": path, "offset": str(offset), "length": str(length)},
            headers=_auth_headers(),
        )
        resp.raise_for_status()
        return resp.content, {k.lower(): v for k, v in resp.headers.items()}

    if head_bytes > 0:
        data, hdrs = _range(0, head_bytes)
        out["file_size"] = int(hdrs.get("x-file-size", "0"))
        try:
            out["head_text"] = data.decode("utf-8")
        except UnicodeDecodeError:
            out["head_base64"] = base64.b64encode(data).decode("ascii")
        out["head_bytes_read"] = len(data)

    if tail_bytes > 0:
        size = int(out.get("file_size", 0)) if head_bytes > 0 else int(
            json.loads(iphone_stat(path)).get("size", 0)
        )
        offset = max(0, size - tail_bytes)
        data, hdrs = _range(offset, tail_bytes)
        out.setdefault("file_size", int(hdrs.get("x-file-size", size)))
        try:
            out["tail_text"] = data.decode("utf-8")
        except UnicodeDecodeError:
            out["tail_base64"] = base64.b64encode(data).decode("ascii")
        out["tail_bytes_read"] = len(data)
        out["tail_offset"] = offset

    return json.dumps(out, indent=2)


@mcp.tool()
def iphone_edit(path: str, old_string: str, new_string: str, count: int = 1) -> str:
    """Server-side exact string replace on a UTF-8 text file.

    Mirrors Claude's Edit tool semantics: the server validates the match
    count, replaces in place, and returns only {replacements, new_size} —
    keeping file content entirely OUT of Claude's context.

    Args:
        path: Absolute path to a UTF-8 text file on the iPhone.
        old_string: Exact substring to replace. Must not be empty.
        new_string: Replacement.
        count: Expected occurrence count. Default 1 (errors if ambiguous).
               Pass 0 to replace all occurrences.
    """
    return json.dumps(
        _post("edit", {
            "path": path,
            "old_string": old_string,
            "new_string": new_string,
            "count": count,
        }),
        indent=2,
    )


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
        retry=False,
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
        retry=False,
    )
    return json.dumps({
        "local_dir": os.path.abspath(local_dir),
        "remote_dir": remote_dir,
        "files_zipped": file_count,
        "uncompressed_bytes": total_bytes,
        "zip_bytes": zip_size,
        "server": result,
    }, indent=2)


@mcp.tool()
def iphone_discover(timeout_sec: float = 3.0) -> str:
    """Discover ClaudeFileServer instances on the LAN via mDNS/Bonjour.

    Requires the `zeroconf` Python package (pip install zeroconf). Returns
    a list of {name, host, port, version} entries — paste the matching
    host into IPHONE_HOST in ~/.claude.json.

    Args:
        timeout_sec: How long to listen for service announcements. Default 3s.
    """
    try:
        from zeroconf import ServiceBrowser, Zeroconf
    except ImportError:
        raise RuntimeError(
            "zeroconf not installed. `pip install zeroconf` (bridge venv) "
            "to use mDNS discovery. Or set IPHONE_HOST manually in ~/.claude.json."
        )
    import socket as _socket

    found: list[dict[str, Any]] = []

    class _Listener:
        def add_service(self, zc: Any, type_: str, name: str) -> None:
            info = zc.get_service_info(type_, name)
            if info is None:
                return
            addrs = info.parsed_scoped_addresses() if hasattr(info, "parsed_scoped_addresses") else []
            if not addrs:
                addrs = [_socket.inet_ntoa(a) for a in getattr(info, "addresses", []) if len(a) == 4]
            props = {
                (k.decode() if isinstance(k, bytes) else k):
                (v.decode() if isinstance(v, bytes) else v)
                for k, v in (info.properties or {}).items()
            }
            found.append({
                "name": name.split(".")[0],
                "hosts": addrs,
                "port": info.port,
                "version": props.get("version", ""),
            })

        def update_service(self, *args: Any, **kwargs: Any) -> None: pass
        def remove_service(self, *args: Any, **kwargs: Any) -> None: pass

    zc = Zeroconf()
    try:
        ServiceBrowser(zc, "_claude-file-server._tcp.local.", _Listener())
        time.sleep(timeout_sec)
    finally:
        zc.close()

    return json.dumps({"found": found, "count": len(found)}, indent=2)


if __name__ == "__main__":
    mcp.run()

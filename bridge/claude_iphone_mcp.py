"""
ClaudeFileServer MCP Bridge — Gives Claude Code native tools to access iPhone files.

Multi-phone configuration:
    Phones are registered in ~/.iphone_bridge.json (host, port, token, name).
    If that file is missing but IPHONE_HOST/IPHONE_TOKEN env vars are set,
    the bridge auto-bootstraps them as the first registered phone.

    Tools:
        iphone_discover()              — LAN-scan for ClaudeFileServer responders
        iphone_pair(host)              — in-app approval flow; no token copy-paste
        iphone_register(host, token)   — add a phone to the config (if you already have a token)
        iphone_ping(name_or_host="")   — quick health check; no auth
        iphone_list_phones()           — show registered phones + which is active (+reachability)
        iphone_select(name_or_host)    — switch the active phone for subsequent calls
        iphone_unregister(name_or_host)— remove a phone

Install: pip install -r requirements.txt
Run: python claude_iphone_mcp.py
"""

import base64
import concurrent.futures
import hashlib
import ipaddress
import json
import os
import pathlib
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP

CONFIG_PATH = pathlib.Path.home() / ".iphone_bridge.json"

mcp = FastMCP("iphone-file-server")


_CONFIG_HINT = (
    "No phones configured. Run iphone_discover() to scan the LAN, then "
    "iphone_register(host, token, name) with the token shown in the app. "
    "Or set IPHONE_HOST / IPHONE_TOKEN env vars for a single-phone setup."
)


def _load_config() -> dict[str, Any]:
    if CONFIG_PATH.exists():
        try:
            return json.loads(CONFIG_PATH.read_text())
        except (OSError, json.JSONDecodeError):
            pass
    # Bootstrap from env for single-phone setup. Preserves backward compat
    # with existing ~/.claude.json configurations.
    env_host = os.environ.get("IPHONE_HOST", "")
    env_token = os.environ.get("IPHONE_TOKEN", "")
    if env_host and env_token:
        return {
            "active": "env",
            "phones": [{
                "name": "env",
                "host": env_host,
                "port": os.environ.get("IPHONE_PORT", "8080"),
                "token": env_token,
            }],
        }
    return {"active": None, "phones": []}


def _save_config(cfg: dict[str, Any]) -> None:
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2))
    # Tokens live in this file — restrict to owner-only.
    try:
        CONFIG_PATH.chmod(0o600)
    except OSError:
        pass


def _active_phone() -> dict[str, str]:
    cfg = _load_config()
    phones = cfg.get("phones") or []
    if not phones:
        raise RuntimeError(_CONFIG_HINT)
    active_name = cfg.get("active")
    for p in phones:
        if p["name"] == active_name:
            return p
    return phones[0]


def _base_url() -> str:
    p = _active_phone()
    return f"http://{p['host']}:{p.get('port', '8080')}/api"


def _auth_headers() -> dict[str, str]:
    p = _active_phone()
    return {"Authorization": f"Bearer {p['token']}"}


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


# --- Multi-phone: discovery + registration ----------------------------------

def _local_ipv4_subnets() -> list[ipaddress.IPv4Network]:
    """Return /24 subnets for this machine's non-loopback IPv4 interfaces.

    We deliberately cap to /24 even if the interface has a wider netmask,
    to keep the scan bounded. Most home LANs are /24 anyway.
    """
    subnets: list[ipaddress.IPv4Network] = []
    try:
        out = subprocess.run(
            ["ip", "-4", "-o", "addr"],
            capture_output=True, text=True, timeout=2.0,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return subnets
    # Skip interfaces that are obviously virtual bridges (docker, KVM, etc.)
    # where no iPhone will ever be reachable.
    skip_prefixes = ("docker", "br-", "virbr", "veth", "tun", "tap", "podman")
    for line in out.splitlines():
        parts = line.split()
        try:
            ifname = parts[1]
            cidr = parts[3]  # e.g. 192.168.1.210/24
        except IndexError:
            continue
        if any(ifname.startswith(p) for p in skip_prefixes):
            continue
        try:
            iface = ipaddress.ip_interface(cidr)
        except ValueError:
            continue
        if not isinstance(iface.network, ipaddress.IPv4Network):
            continue
        if iface.ip.is_loopback or iface.ip.is_link_local:
            continue
        # Force to /24 around this address to bound the scan.
        octets = str(iface.ip).split(".")
        net = ipaddress.ip_network(f"{'.'.join(octets[:3])}.0/24")
        if net not in subnets:
            subnets.append(net)
    return subnets


def _probe_ping(host: str, port: str, timeout: float) -> dict[str, Any] | None:
    """Hit GET http://host:port/api/ping (unauthenticated). Return parsed
    JSON on success, None on any failure. Used by iphone_discover only."""
    url = f"http://{host}:{port}/api/ping"
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return None
            body = resp.read(8192)
            data = json.loads(body.decode("utf-8"))
    except Exception:
        return None
    if data.get("service") != "claude-file-server":
        return None
    data["host"] = host
    data["port"] = port
    return data


@mcp.tool()
def iphone_discover(port: str = "8080", fast_timeout_sec: float = 0.5,
                    slow_timeout_sec: float = 1.5, workers: int = 64) -> str:
    """LAN-scan for ClaudeFileServer instances. Returns the device name,
    model, iOS version, and server version of every responder — no auth
    needed (the /api/ping endpoint is open).

    Two-pass scan: first pass at `fast_timeout_sec` catches awake phones
    quickly; second pass re-probes the non-responders at `slow_timeout_sec`
    so phones whose WiFi radio was asleep on the first hit still get
    discovered. Total worst case ≈ (fast + slow) for a /24.

    Paste a host into `iphone_register(host="…", token="…", name="…")`
    with the token from that phone's ClaudeFileServer UI, OR use
    iphone_pair(host="…") to prompt the user to approve the connection
    in-app and auto-save the token.

    Args:
        port: TCP port to probe. Default 8080.
        fast_timeout_sec: First-pass per-host timeout. Default 0.5s.
        slow_timeout_sec: Second-pass timeout for non-responders. Default 1.5s.
        workers: Parallel probes. Default 64.
    """
    subnets = _local_ipv4_subnets()
    if not subnets:
        raise RuntimeError("Could not determine local IPv4 subnets")
    hosts = [str(h) for net in subnets for h in net.hosts()]
    found: dict[str, dict[str, Any]] = {}

    def _scan(targets: list[str], timeout: float) -> None:
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
            for host, result in zip(
                targets,
                ex.map(lambda h: _probe_ping(h, port, timeout), targets),
            ):
                if result is not None:
                    found[host] = result

    _scan(hosts, fast_timeout_sec)
    # Retry only the silent hosts. Skips the hosts we already found so the
    # total is bounded.
    missed = [h for h in hosts if h not in found]
    if missed:
        _scan(missed, slow_timeout_sec)

    return json.dumps({
        "subnets_scanned": [str(s) for s in subnets],
        "hosts_probed": len(hosts),
        "found": list(found.values()),
        "count": len(found),
    }, indent=2)


@mcp.tool()
def iphone_pair(host: str, name: str = "", port: str = "8080") -> str:
    """Pair with an iPhone without copy-pasting the token.

    Flow: (1) the user opens ClaudeFileServer on the target phone and taps
    'Accept Pairing Requests' to open a 60s window; (2) this tool POSTs
    /api/pair_request; (3) a confirmation prompt appears on the phone;
    (4) on approval, the server returns the token and this tool saves it
    to ~/.iphone_bridge.json and makes the phone active.

    The server blocks the HTTP response for up to 30s waiting for the
    user's tap, so plan for a short wait.

    Args:
        host: iPhone LAN IP address.
        name: Optional label. Defaults to the phone's configured label
              (or iOS device name).
        port: Default 8080.
    """
    import socket as _socket
    requester = f"Claude Code @ {_socket.gethostname()}"
    fingerprint = hashlib.sha256(
        f"{_socket.gethostname()}|{os.getuid() if hasattr(os, 'getuid') else ''}".encode()
    ).hexdigest()[:16]

    try:
        resp = httpx.post(
            f"http://{host}:{port}/api/pair_request",
            json={"requester": requester, "fingerprint": fingerprint},
            timeout=35.0,  # server-side timeout is 30s; add slack for the response.
        )
    except Exception as exc:
        raise RuntimeError(f"Could not reach {host}:{port} — is the server running? ({exc})")

    if resp.status_code == 403:
        msg = resp.json().get("error", "Forbidden")
        raise RuntimeError(
            f"Pair rejected: {msg}. "
            "Open ClaudeFileServer on the phone, tap 'Accept Pairing Requests' to "
            "open the 60s window, then retry iphone_pair()."
        )
    if resp.status_code == 408:
        raise RuntimeError("The user didn't approve in time — try again.")
    resp.raise_for_status()
    data = resp.json()
    token = data["token"]
    device_name = data.get("device_name", host)
    final_name = name or device_name

    cfg = _load_config()
    cfg.setdefault("phones", [])
    cfg["phones"] = [p for p in cfg["phones"]
                     if p["name"] != final_name and p["host"] != host]
    cfg["phones"].append({
        "name": final_name, "host": host, "port": port, "token": token,
    })
    # Pairing a phone implies you want to use it next — always flip active.
    cfg["active"] = final_name
    _save_config(cfg)

    return json.dumps({
        "paired": final_name,
        "host": host,
        "port": port,
        "device_name": device_name,
        "active": cfg["active"],
        "total_phones": len(cfg["phones"]),
    }, indent=2)


@mcp.tool()
def iphone_register(host: str, token: str, name: str = "",
                    port: str = "8080") -> str:
    """Register an iPhone with the bridge. Verifies the token against
    /api/info, then stores {name, host, port, token} in ~/.iphone_bridge.json.
    If no `name` is provided, the phone's own device name is used.

    Becomes the active phone if none was set.

    Args:
        host: iPhone LAN IP address.
        token: Auth token shown in the ClaudeFileServer app.
        name: Optional label (e.g. "iPhone 16"). Defaults to device name.
        port: Default 8080.
    """
    try:
        resp = httpx.get(
            f"http://{host}:{port}/api/info",
            headers={"Authorization": f"Bearer {token}"},
            timeout=5.0,
        )
        resp.raise_for_status()
        info = resp.json()
    except Exception as exc:
        raise RuntimeError(f"Could not reach {host}:{port} with that token: {exc}")

    device_name = info.get("device", {}).get("name", host)
    final_name = name or device_name

    cfg = _load_config()
    cfg.setdefault("phones", [])
    # Remove any prior entry with the same name OR same host — we're
    # re-registering either way.
    cfg["phones"] = [p for p in cfg["phones"]
                     if p["name"] != final_name and p["host"] != host]
    cfg["phones"].append({
        "name": final_name,
        "host": host,
        "port": port,
        "token": token,
    })
    if not cfg.get("active") or cfg.get("active") == "env":
        cfg["active"] = final_name
    _save_config(cfg)

    return json.dumps({
        "registered": final_name,
        "host": host,
        "port": port,
        "device_name": device_name,
        "active": cfg["active"],
        "total_phones": len(cfg["phones"]),
    }, indent=2)


@mcp.tool()
def iphone_list_phones(probe: bool = True,
                       probe_timeout_sec: float = 0.6) -> str:
    """List registered iPhones and which one is active. Tokens are redacted.

    If `probe` is True (default), each phone is pinged in parallel via
    /api/ping and the response (or 'offline') is attached as `reachable`.

    Args:
        probe: Ping each phone to fill in reachability. Default True.
        probe_timeout_sec: Per-phone timeout when probing. Default 0.6s.
    """
    cfg = _load_config()
    phones = cfg.get("phones", [])

    results: dict[str, dict[str, Any]] = {}
    if probe and phones:
        def _check(p: dict[str, Any]) -> tuple[str, dict[str, Any] | None]:
            return p["name"], _probe_ping(p["host"], p.get("port", "8080"),
                                          probe_timeout_sec)
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(phones))) as ex:
            for name, ping in ex.map(_check, phones):
                results[name] = ping or {}

    out = []
    for p in phones:
        ping = results.get(p["name"]) or {}
        out.append({
            "name": p["name"],
            "host": p["host"],
            "port": p.get("port", "8080"),
            "token_prefix": (p["token"][:6] + "…") if p.get("token") else "",
            "reachable": bool(ping) if probe else None,
            "server_version": ping.get("server_version", "") if ping else "",
            "device_name": ping.get("device_name", "") if ping else "",
        })
    return json.dumps({
        "active": cfg.get("active"),
        "phones": out,
        "config_path": str(CONFIG_PATH),
    }, indent=2)


@mcp.tool()
def iphone_ping(name_or_host: str = "") -> str:
    """Quick health check — hit /api/ping on a phone (no auth needed).

    Args:
        name_or_host: Which phone to ping. Empty = active phone.
    """
    cfg = _load_config()
    if name_or_host:
        target = None
        for p in cfg.get("phones", []):
            if p["name"] == name_or_host or p["host"] == name_or_host:
                target = p
                break
        if target is None:
            # Allow pinging an unregistered host too.
            target = {"host": name_or_host, "port": "8080", "name": name_or_host}
    else:
        target = _active_phone()
    result = _probe_ping(target["host"], target.get("port", "8080"), 2.0)
    if result is None:
        raise RuntimeError(f"No response from {target['host']}:{target.get('port', '8080')}")
    return json.dumps(result, indent=2)


@mcp.tool()
def iphone_select(name_or_host: str) -> str:
    """Switch the active iPhone for subsequent tool calls. Match is by
    name first, host second.
    """
    cfg = _load_config()
    for p in cfg.get("phones", []):
        if p["name"] == name_or_host or p["host"] == name_or_host:
            cfg["active"] = p["name"]
            _save_config(cfg)
            return json.dumps({
                "active": p["name"],
                "host": p["host"],
                "port": p.get("port", "8080"),
            }, indent=2)
    known = [p["name"] for p in cfg.get("phones", [])]
    raise RuntimeError(f"No registered phone matches '{name_or_host}'. Known: {known}")


@mcp.tool()
def iphone_unregister(name_or_host: str) -> str:
    """Remove an iPhone from the registered list. If the active phone is
    removed, the first remaining phone becomes active (or None if empty).
    """
    cfg = _load_config()
    before = len(cfg.get("phones", []))
    cfg["phones"] = [p for p in cfg.get("phones", [])
                     if p["name"] != name_or_host and p["host"] != name_or_host]
    after = len(cfg["phones"])
    names = {p["name"] for p in cfg["phones"]}
    if cfg.get("active") not in names:
        cfg["active"] = cfg["phones"][0]["name"] if cfg["phones"] else None
    _save_config(cfg)
    return json.dumps({
        "removed": before - after,
        "remaining": after,
        "active": cfg.get("active"),
    }, indent=2)


if __name__ == "__main__":
    mcp.run()

# ClaudeFileServer

Remote file access for Claude Code (WSL) to browse and edit files on an iPhone running LiveContainer.

## Components

1. **iOS App** — Lightweight SwiftUI app with embedded HTTP server exposing a REST API for file operations
2. **MCP Bridge** — Python MCP server giving Claude Code native `iphone_*` tools
3. **Shell Bridge** — Bash/curl wrapper for manual testing

## Building

### GitHub Actions (recommended)
Push to `main` — the workflow builds an unsigned IPA automatically. Download from the Actions artifacts tab.

### Local (requires macOS with Xcode 15+)
```bash
cd ClaudeFileServer
xcodebuild archive \
  -project ClaudeFileServer.xcodeproj \
  -scheme ClaudeFileServer \
  -configuration Release \
  -archivePath build/ClaudeFileServer.xcarchive \
  -destination "generic/platform=iOS" \
  CODE_SIGNING_ALLOWED=NO

cd build && mkdir Payload
cp -r ClaudeFileServer.xcarchive/Products/Applications/ClaudeFileServer.app Payload/
zip -r ClaudeFileServer-unsigned.ipa Payload
```

## Installation

1. Import the unsigned IPA into **LiveContainer** (via SideStore or AltStore)
2. Launch ClaudeFileServer inside LiveContainer
3. Toggle the server on
4. Note the **IP address**, **port**, and **auth token** displayed

## Usage

### Quick test with curl
```bash
export IPHONE_HOST=192.168.1.x
export IPHONE_PORT=8080
export IPHONE_TOKEN=<token from app>

curl http://$IPHONE_HOST:$IPHONE_PORT/api/info -H "Authorization: Bearer $IPHONE_TOKEN"
```

### Shell bridge
```bash
cd bridge
export IPHONE_HOST=192.168.1.x IPHONE_TOKEN=<token>
./iphone_bridge.sh info
./iphone_bridge.sh ls /path/to/dir
./iphone_bridge.sh read /path/to/file.txt
./iphone_bridge.sh write /path/to/file.txt "new content"
```

### MCP Server (Claude Code integration)

Install dependencies:
```bash
cd bridge
pip install -r requirements.txt
```

Add to your Claude Code MCP config (`~/.claude/mcp_config.json`):
```json
{
  "mcpServers": {
    "iphone": {
      "command": "python",
      "args": ["/absolute/path/to/bridge/claude_iphone_mcp.py"],
      "env": {
        "IPHONE_HOST": "192.168.1.x",
        "IPHONE_PORT": "8080",
        "IPHONE_TOKEN": "<token from app>"
      }
    }
  }
}
```

Restart Claude Code. You'll have these tools available:
- `iphone_info` — Device info and accessible paths
- `iphone_ls` — List directory
- `iphone_ls_recursive` — Walk a tree server-side in one MCP call
- `iphone_read` — Read file
- `iphone_write` — Write file (UTF-8 or base64)
- `iphone_upload_binary` — PUT a local file as raw bytes
- `iphone_pull` — Stream a remote file to local disk (content stays out of context)
- `iphone_delete` — Delete file/directory
- `iphone_mkdir` — Create directory
- `iphone_extract_zip` — Upload a local zip, extract on phone (after IPA update)
- `iphone_create_zip` — Zip a remote dir and pull locally (after IPA update)
- `iphone_sync` — Zip local dir → upload → extract on phone (one-shot tree install)

## API Endpoints

All endpoints require `Authorization: Bearer <token>` header.

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/info` | Device info + accessible paths |
| GET | `/api/ls?path=...` | List directory |
| GET | `/api/read?path=...` | Read file (UTF-8 or base64) |
| POST | `/api/write` | Write file `{path, content, encoding}` |
| PUT | `/api/upload?path=...` | Upload raw binary body (no JSON/base64 overhead) |
| POST | `/api/append?path=...` | Append raw binary body to file |
| DELETE | `/api/delete?path=...` | Delete file/directory |
| POST | `/api/mkdir` | Create directory `{path}` |
| POST | `/api/zip_extract?path=<dir>` | Body is `application/zip` — unzip into `<dir>`. Returns `{files_extracted, bytes_written}` |
| GET | `/api/zip_create?path=<dir>` | Streams back a `application/zip` of `<dir>` (built via `NSFileCoordinator` `.forUploading`) |

## Architecture Notes

- **No private APIs** — pure public SDK, safe for LiveContainer
- **No background modes** — avoids LC crash triggers
- **GCDWebServer** vendored as source — zero external dependencies
- **ZIPFoundation** (MIT, weichsel/ZIPFoundation 0.9.20) vendored under `Vendor/ZIPFoundation/` as source, not SwiftPM. The zlib branch of `Data+Compression.swift` is disabled so no `libz.tbd` linkage is required; the pure-Swift `builtInCRC32` fallback is used instead.
- **Sandbox-aware** — LC guest apps share the same sandbox container, so files from other LC apps are accessible

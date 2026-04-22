#!/usr/bin/env bash
# iphone_bridge.sh — Simple curl wrapper for ClaudeFileServer API
# Usage: ./iphone_bridge.sh <command> [args...]
#
# Environment variables (or set defaults below):
#   IPHONE_HOST  — iPhone IP address
#   IPHONE_PORT  — Server port (default: 8080)
#   IPHONE_TOKEN — Auth token

set -euo pipefail

HOST="${IPHONE_HOST:?Set IPHONE_HOST to your iPhone's IP address}"
PORT="${IPHONE_PORT:-8080}"
TOKEN="${IPHONE_TOKEN:?Set IPHONE_TOKEN to the auth token shown in the app}"

BASE_URL="http://${HOST}:${PORT}/api"
AUTH_HEADER="Authorization: Bearer ${TOKEN}"

usage() {
    cat <<'EOF'
Commands:
  info                      — Device info and accessible paths
  ls <path>                 — List directory contents
  read <path>               — Read file contents
  write <path> <content>    — Write content to file (UTF-8)
  writeb64 <path> <base64>  — Write base64-encoded content to file
  delete <path>             — Delete file or directory
  mkdir <path>              — Create directory

Examples:
  ./iphone_bridge.sh info
  ./iphone_bridge.sh ls /var/mobile/Containers/Data/Application
  ./iphone_bridge.sh read /path/to/file.txt
  ./iphone_bridge.sh write /path/to/file.txt "hello world"
  ./iphone_bridge.sh mkdir /path/to/new/dir
EOF
}

case "${1:-}" in
    info)
        curl -s "${BASE_URL}/info" -H "${AUTH_HEADER}" | python3 -m json.tool
        ;;
    ls)
        [[ -z "${2:-}" ]] && { echo "Error: path required"; exit 1; }
        curl -s "${BASE_URL}/ls?path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$2'))")" \
            -H "${AUTH_HEADER}" | python3 -m json.tool
        ;;
    read)
        [[ -z "${2:-}" ]] && { echo "Error: path required"; exit 1; }
        curl -s "${BASE_URL}/read?path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$2'))")" \
            -H "${AUTH_HEADER}" | python3 -m json.tool
        ;;
    write)
        [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Error: path and content required"; exit 1; }
        curl -s -X POST "${BASE_URL}/write" \
            -H "${AUTH_HEADER}" \
            -H "Content-Type: application/json" \
            -d "$(python3 -c "import json; print(json.dumps({'path': '$2', 'content': '$3', 'encoding': 'utf-8'}))")" \
            | python3 -m json.tool
        ;;
    writeb64)
        [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Error: path and base64 content required"; exit 1; }
        curl -s -X POST "${BASE_URL}/write" \
            -H "${AUTH_HEADER}" \
            -H "Content-Type: application/json" \
            -d "$(python3 -c "import json; print(json.dumps({'path': '$2', 'content': '$3', 'encoding': 'base64'}))")" \
            | python3 -m json.tool
        ;;
    delete)
        [[ -z "${2:-}" ]] && { echo "Error: path required"; exit 1; }
        curl -s -X DELETE "${BASE_URL}/delete?path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$2'))")" \
            -H "${AUTH_HEADER}" | python3 -m json.tool
        ;;
    mkdir)
        [[ -z "${2:-}" ]] && { echo "Error: path required"; exit 1; }
        curl -s -X POST "${BASE_URL}/mkdir" \
            -H "${AUTH_HEADER}" \
            -H "Content-Type: application/json" \
            -d "$(python3 -c "import json; print(json.dumps({'path': '$2'}))")" \
            | python3 -m json.tool
        ;;
    *)
        usage
        ;;
esac

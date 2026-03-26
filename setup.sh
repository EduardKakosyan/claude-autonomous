#!/bin/bash
set -euo pipefail

# ── Claude Autonomous Environment Setup ──────────────────
# Clones this repo, builds the container, configures launchd,
# and connects to a project workspace. One command to go.
#
# Usage:
#   ./setup.sh                          # Interactive setup
#   ./setup.sh /path/to/project         # With existing project
#   ./setup.sh --workspace-only         # Skip container rebuild

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="claude-autonomous"

echo "=== Claude Autonomous Environment Setup ==="
echo ""

# ── Check prerequisites ──────────────────────────────────
echo "Checking prerequisites..."
MISSING=()
command -v docker &>/dev/null || MISSING+=("docker (install OrbStack: brew install orbstack)")
command -v jq &>/dev/null || MISSING+=("jq (brew install jq)")
command -v gdate &>/dev/null || MISSING+=("coreutils (brew install coreutils)")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "ERROR: Missing prerequisites:"
    for dep in "${MISSING[@]}"; do
        echo "  - $dep"
    done
    exit 1
fi

# Check Docker/OrbStack is running
if ! docker info &>/dev/null; then
    echo "ERROR: Docker is not running. Start OrbStack first."
    exit 1
fi

echo "All prerequisites found."
echo ""

# ── Create directories ───────────────────────────────────
echo "Creating directory structure..."
mkdir -p "$SCRIPT_DIR"/{workspace,scripts/state,logs}

# ── Workspace setup ──────────────────────────────────────
if [[ "${1:-}" == "--workspace-only" ]]; then
    echo "Skipping container build (--workspace-only)"
elif [[ -n "${1:-}" && -d "$1" ]]; then
    echo "Linking workspace to: $1"
    rm -rf "$SCRIPT_DIR/workspace"
    ln -s "$(cd "$1" && pwd)" "$SCRIPT_DIR/workspace"
fi

if [[ "${1:-}" != "--workspace-only" ]]; then
    # ── Build container ──────────────────────────────────
    echo ""
    echo "Building container image..."
    cd "$SCRIPT_DIR"
    docker build -t "$CONTAINER_NAME:latest" -f Dockerfile . 2>&1 | tail -5

    # ── Stop old container if running ────────────────────
    if docker inspect "$CONTAINER_NAME" &>/dev/null; then
        echo "Stopping existing container..."
        docker stop "$CONTAINER_NAME" &>/dev/null || true
        docker rm "$CONTAINER_NAME" &>/dev/null || true
    fi

    # ── Start container ──────────────────────────────────
    echo "Starting container..."
    docker run -d --name "$CONTAINER_NAME" \
        --cap-add=NET_ADMIN \
        --cpus=4 --memory=8g --pids-limit=256 \
        -v "$SCRIPT_DIR/workspace":/workspace \
        -v claude-config:/home/claude/.claude \
        -e CLAUDE_CODE_MAX_OUTPUT_TOKENS=32768 \
        -e CLAUDE_CODE_EFFORT_LEVEL=high \
        -e DISABLE_AUTOUPDATER=1 \
        "$CONTAINER_NAME:latest" sleep infinity >/dev/null

    # ── Initialize firewall ──────────────────────────────
    echo "Initializing firewall..."
    docker exec "$CONTAINER_NAME" sudo /usr/local/bin/init-firewall.sh

    # ── Inject OAuth credentials ─────────────────────────
    echo "Injecting OAuth credentials from keychain..."
    CREDS=$(security find-generic-password -s "Claude Code-credentials" \
        -a "$(whoami)" -w 2>/dev/null || true)
    if [[ -n "$CREDS" ]]; then
        docker exec "$CONTAINER_NAME" sudo bash -c \
            "echo '$CREDS' > /home/claude/.claude/.credentials.json \
            && chmod 600 /home/claude/.claude/.credentials.json \
            && chown claude:claude /home/claude/.claude/.credentials.json"
        echo "  Credentials injected."
    else
        echo "  WARNING: No OAuth credentials found. Run: docker exec -it $CONTAINER_NAME claude"
    fi
fi

# ── Install launchd job ──────────────────────────────────
echo ""
echo "Installing launchd nightly job..."
PLIST_SRC="$SCRIPT_DIR/local.claude-nightly.plist"
PLIST_DST="$HOME/Library/LaunchAgents/local.claude-nightly.plist"

# Update HOMEDIR in plist if still templated
if grep -q "HOMEDIR" "$PLIST_SRC" 2>/dev/null; then
    sed -i '' "s|HOMEDIR|$HOME|g" "$PLIST_SRC"
fi

cp "$PLIST_SRC" "$PLIST_DST"
launchctl bootout "gui/$(id -u)/local.claude-nightly" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
echo "  Nightly job installed (2:00 AM daily)"

# ── Configure git hooks in workspace ─────────────────────
if [[ -d "$SCRIPT_DIR/workspace/.git" && -d "$SCRIPT_DIR/workspace/.githooks" ]]; then
    echo ""
    echo "Configuring git hooks in workspace..."
    cd "$SCRIPT_DIR/workspace" && git config core.hooksPath .githooks
    echo "  Git hooks configured."
fi

# ── Verify ───────────────────────────────────────────────
echo ""
echo "=== Verification ==="
docker exec "$CONTAINER_NAME" claude --version 2>/dev/null && echo "  Claude Code: OK"
docker exec "$CONTAINER_NAME" go version 2>/dev/null && echo "  Go: OK"
docker exec "$CONTAINER_NAME" golangci-lint version --short 2>/dev/null && echo "  golangci-lint: OK"
echo ""

echo "=== Setup Complete ==="
echo ""
echo "Quick reference:"
echo "  Manual run:     ~/$(basename "$SCRIPT_DIR")/scripts/claude-nightly.sh"
echo "  Shell into:     docker exec -it $CONTAINER_NAME bash"
echo "  Interactive:    docker exec -it $CONTAINER_NAME claude"
echo "  Watch logs:     tail -f ~/$(basename "$SCRIPT_DIR")/logs/launchd-stdout.log"
echo "  Mac wake:       sudo pmset repeat wakeorpoweron MTWRFSU 01:55:00"
echo ""

#!/usr/bin/env bash
set -euo pipefail

GPG_PORT=16448
EXPORT_EMAIL=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --export=*)
      EXPORT_EMAIL="${1#*=}"
      shift
      ;;
    *)
      REMOTE_HOST="$1"
      shift
      ;;
  esac
done

if [ -z "${REMOTE_HOST:-}" ]; then
  echo "Usage: $0 [--export=your@email.com] <remote-host>"
  exit 1
fi

# Find Windows GPG agent socket path and convert it correctly
ASSUAN_FILE="$(find /mnt/c/Users/${USER}/AppData/local/gnupg -iname S.gpg-agent)"
if [ -z "$ASSUAN_FILE" ]; then
  echo "❌ ERROR: Could not find the GPG agent socket file"
  echo "Check if the GPG agent is running in Windows."
  exit 1
fi

# Export keys if requested
if [ -n "$EXPORT_EMAIL" ]; then
  # Create a temporary directory for key export
  TMP_KEY_DIR=$(mktemp -d)
  PUBKEY_FILE="$TMP_KEY_DIR/pubkey.asc"

  # Export public keys
  if ! gpg --export --armor "$EXPORT_EMAIL" > "$PUBKEY_FILE"; then
    echo "❌ ERROR: Failed to export public keys for $EXPORT_EMAIL"
    rm -rf "$TMP_KEY_DIR"
    exit 1
  fi

  # Check if the export was successful
  if [ ! -s "$PUBKEY_FILE" ]; then
    echo "❌ ERROR: No public keys found for $EXPORT_EMAIL"
    rm -rf "$TMP_KEY_DIR"
    exit 1
  fi

  # Display key information
  # gpg --show-keys "$PUBKEY_FILE"
  echo "GPG keys exported for $EXPORT_EMAIL locally"

  # Send the public keys to the remote host
  # echo "Transferring public keys to $REMOTE_HOST"
  if ! scp -q "$PUBKEY_FILE" "$REMOTE_HOST:/tmp/pubkey.asc"; then
    echo "❌ ERROR: Failed to transfer public keys to $REMOTE_HOST"
    rm -rf "$TMP_KEY_DIR"
    exit 1
  fi

  # Import the public keys on the remote host
  if ! ssh "$REMOTE_HOST" "gpg --import /tmp/pubkey.asc && rm -f /tmp/pubkey.asc"; then
    echo "❌ ERROR: Failed to import public keys on $REMOTE_HOST"
    rm -rf "$TMP_KEY_DIR"
    exit 1
  fi

  echo "✅ GPG keys imported for $EXPORT_EMAIL remotely on $REMOTE_HOST"
  rm -rf "$TMP_KEY_DIR"
  echo ""
fi

# Convert path for npiperelay - using a different approach
# First get Windows style path with wslpath
WIN_PATH="$(wslpath -w "$ASSUAN_FILE")"
# Then properly escape backslashes for command line
WIN_ASSUAN_FILE=$(echo "$WIN_PATH" | sed 's/\\/\\\\\\\\/g')

# Setup cleanup function
cleanup() {
  echo "Cleaning up local resources"
  kill $SOCAT_PID 2>/dev/null || true
  rm -f "$TMP_SCRIPT" 2>/dev/null || true
  echo "Local GPG forwarding stopped"
}

# Register cleanup on script exit and signals
trap cleanup EXIT SIGINT SIGTERM

# Kill any existing socat processes
pkill -f "socat.*gpg-agent" || true

# Start socat for main GPG agent socket - forward Windows socket to TCP port
echo "Start npiperelay for local named pipe -> TCP socket"
socat TCP4-LISTEN:${GPG_PORT},bind=localhost,fork,reuseaddr \
    EXEC:"npiperelay.exe -ei -ep -a \"${WIN_ASSUAN_FILE}\"" &
SOCAT_PID=$!

# Create remote setup script with added verification step
TMP_SCRIPT=$(mktemp)
cat > "$TMP_SCRIPT" << 'EOF'
#!/bin/bash
GPG_PORT=16448
REMOTE_SOCAT_PID=""

# Remote cleanup function
remote_cleanup() {
  echo "Cleaning up remote resources"
  if [ -n "$REMOTE_SOCAT_PID" ]; then
    kill $REMOTE_SOCAT_PID 2>/dev/null || true
  fi
  # Kill any other socat processes that might be related
  pkill -f "socat.*gnupg.*${GPG_PORT}" 2>/dev/null || true
  echo "Remote GPG forwarding stopped"
  exit 0
}

# Register remote cleanup for all exit scenarios
trap remote_cleanup EXIT SIGINT SIGTERM

# Setup directories
mkdir -p ~/.gnupg /run/user/$(id -u)/gnupg
chmod 700 ~/.gnupg /run/user/$(id -u)/gnupg

# Kill any existing socat processes
pkill -f "socat.*gnupg.*${GPG_PORT}" || true

# Create a Unix socket that forwards to the TCP port
socat UNIX-LISTEN:/run/user/$(id -u)/gnupg/S.gpg-agent,fork,unlink-early,mode=600 \
    TCP:localhost:${GPG_PORT} &
REMOTE_SOCAT_PID=$!

# Add no-autostart to gpg.conf if not already present
if ! grep -q "^no-autostart" ~/.gnupg/gpg.conf 2>/dev/null; then
  echo "no-autostart" >> ~/.gnupg/gpg.conf
  echo "Remote gpg.conf appended with 'no-autostart' to prevent starting its own gpg-agent"
fi

# Wait for socat socket to be ready
echo "Waiting up to 5s for remote socket to be ready"
MAX_TRIES=10
for ((i=1; i<=$MAX_TRIES; i++)); do
  if [ -S "/run/user/$(id -u)/gnupg/S.gpg-agent" ]; then
    # GPG socket is ready
    break
  fi

  if [ $i -eq $MAX_TRIES ]; then
    echo "⚠️ WARNING: Socket not ready after $MAX_TRIES attempts" >&2
    echo "Continuing anyway, but connection may fail" >&2
  fi

  sleep 0.5
done

# Verify GPG agent connection
echo "Verify GPG agent connection"
GPG_AGENT_RESPONSE=$(gpg-connect-agent "getinfo version" /bye)
if echo "$GPG_AGENT_RESPONSE" | grep -q "OK"; then
  echo "✅ GPG forwarding connection verified. You can use remote GPG with local keys."
else
  echo "⚠️ WARNING: GPG agent connection could not be verified" >&2
  echo "Response was: $GPG_AGENT_RESPONSE" >&2
fi

echo ""
echo "Press Ctrl+C to stop forwarding and exit"

# Wait for socat to exit (or be killed)
wait $REMOTE_SOCAT_PID
EOF

chmod +x "$TMP_SCRIPT"

# Print status
# GPG Agent is now available via TCP at localhost
echo "Connect to $REMOTE_HOST and setup remote forwarding"

# Copy script to remote host and execute it over SSH with port forwarding
if ! scp -q "$TMP_SCRIPT" "$REMOTE_HOST:/tmp/gpg-forward-remote.sh"; then
  echo "❌ ERROR: Failed to transfer setup script to $REMOTE_HOST"
  exit 1
fi

# Use Remote forwarding with additional options:
# -t: Force terminal allocation to ensure signals are properly forwarded
# This pushes the local GPG port to the remote machine
ssh -t -R localhost:${GPG_PORT}:localhost:${GPG_PORT} "$REMOTE_HOST" "/tmp/gpg-forward-remote.sh"

# Try to kill remote socat even if the remote script failed to do so
ssh "$REMOTE_HOST" "pkill -f 'socat.*gnupg.*${GPG_PORT}' || true"

# No need for cleanup here as the trap will handle it
echo "SSH connection closed"

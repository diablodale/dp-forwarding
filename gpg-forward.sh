#!/usr/bin/env bash
# gpg-forward.sh - A script to forward GPG agent socket from WSL to a remote host
# Copyright (C) Dale Phurrough
# Licensed under the Apache License, Version 2.0
# http://www.apache.org/licenses/LICENSE-2.0
# This script is provided "as-is" without any warranty of any kind.

set -euo pipefail

# Default to auto port selection
GPG_PORT="auto"
EXPORT_EMAIL=""
FORK_MODE=false

# Check dependencies
function app_version_lt_min() {
  if [[ "$(echo -e "$2\n$3" | sort -rV | head -n 1)" != "$2" ]]; then
    echo "❌ ERROR: $1 is older than $3, please update it"
    exit 1
  fi
}
function check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "❌ ERROR: $1 is not installed"
    echo "Please install it with your package manager:"
    if [[ "$cmd" == *".exe" ]]; then
      echo "  winget install $2"
      echo "After installation, make sure it's in your PATH."
    else
      echo "  Ubuntu/Debian: sudo apt install $2"
      echo "  Fedora: sudo dnf install $2"
      echo "  Alpine: sudo apk add $2"
      echo "  Arch: sudo pacman -S $2"
    fi
    exit 1
  fi
  if [[ -n "${3-}" && -n "${4-}" ]]; then
    app_version_lt_min "$1" "$3" "$4"
  fi
}
check_cmd gpg gpg "$(gpg --version | head -n 1 | awk '{print $3}')" "2.3.0"
check_cmd socat socat # developed with 1.8.0.0
check_cmd ssh openssh-client
check_cmd scp openssh-client
check_cmd npiperelay.exe albertony.npiperelay "$(npiperelay.exe -v 2>&1 | head -n 1 | awk '{gsub("v","",$2); print $2}')" "1.8.0"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --export=*)
      EXPORT_EMAIL="${1#*=}"
      shift
      ;;
    --fork)
      FORK_MODE=true
      shift
      ;;
    --port=*)
      GPG_PORT="${1#*=}"
      shift
      ;;
    *)
      REMOTE_HOST="$1"
      shift
      ;;
  esac
done

if [ -z "${REMOTE_HOST:-}" ]; then
  echo "Usage: $0 [--export=your@email.com] [--fork] [--port=NUMBER|auto] <remote-host>"
  exit 1
fi

# Function to check if a port is available
check_port_available() {
  local port=$1

  # Method 1: Try ss (fastest and most modern)
  if command -v ss &>/dev/null; then
    if ! ss -lnt | awk '{print $4}' | grep -q ":$port\$"; then
      return 0  # Port is available
    else
      return 1  # Port is in use
    fi
  fi

  # Method 2: Try netstat (widely available)
  if command -v netstat &>/dev/null; then
    if ! netstat -tuln | grep -q ":$port "; then
      return 0  # Port is available
    else
      return 1  # Port is in use
    fi
  fi

  # Method 3: Pure Bash /dev/tcp approach (invasive)
  if ! (echo >/dev/tcp/127.0.0.1/$port) 2>/dev/null; then
    return 0  # Port is available (connection failed)
  else
    return 1  # Port is in use (connection succeeded)
  fi
}

# Handle port selection
if [[ "$GPG_PORT" == "auto" ]]; then
  # Find a free port in the dynamic/private range (49152-65535)
  while true; do
    SELECTED_PORT=$(shuf -i 49152-65535 -n 1)
    if check_port_available "$SELECTED_PORT"; then
      GPG_PORT=$SELECTED_PORT
      echo "Selected TCP port: $GPG_PORT"
      break
    fi
  done
elif ! [[ "$GPG_PORT" =~ ^[0-9]+$ ]]; then
  echo "❌ ERROR: Invalid port value. Use a number or 'auto'"
  exit 1
fi

# Find Windows GPG agent socket path and convert it correctly
ASSUAN_FILE="$(find /mnt/c/Users/${USER}/AppData/local/gnupg -iname S.gpg-agent)"
if [ -z "$ASSUAN_FILE" ]; then
  echo "❌ ERROR: Could not find the GPG agent socket file in Windows."
  echo "Check if the GPG agent is running in Windows."
  exit 1
fi
WIN_ASSUAN_FILE="$(wslpath -w "$ASSUAN_FILE")"

# Verify GPG agent running in Windows
GPG_AGENT_RESPONSE=$(gpg-connect-agent.exe --no-autostart "getinfo version" /bye 2> /dev/null)
if ! echo "$GPG_AGENT_RESPONSE" | grep -q "OK"; then
  echo "❌ ERROR: GPG agent is not running in Windows."
  echo "Please start Kleopatra or WinGPG and try again."
  exit 1
fi

# Setup cleanup function
cleanup() {
  echo "Cleaning local resources"
  kill ${LOCAL_SOCAT_PID:-} 2>/dev/null || true
  rm -f "${LOCAL_SCRIPT:-}" "${PUBKEY_FILE:-}" 2>/dev/null || true
  echo "Local GPG forwarding stopped"
}

# Register cleanup on script exit and signals
trap 'cleanup; exit 0' INT
trap cleanup EXIT TERM

# Export keys and setup remote forwarding
LOCAL_SCRIPT=$(mktemp)
REMOTE_SCRIPT=$(mktemp -t "gpg-forward-remote-${GPG_PORT}-XXXXXXXX")

# Export public keys if requested
if [ -n "$EXPORT_EMAIL" ]; then
  PUBKEY_FILE=$(mktemp -t "gpg-pubkey-${EXPORT_EMAIL}-XXXXXXXX")

  # Export public keys
  if ! gpg --export --armor "$EXPORT_EMAIL" > "$PUBKEY_FILE"; then
    echo "❌ ERROR: Failed to export public keys for $EXPORT_EMAIL"
    exit 1
  fi

  # Check if the export was successful
  if [ ! -s "$PUBKEY_FILE" ]; then
    echo "❌ ERROR: No public keys found for $EXPORT_EMAIL"
    exit 1
  fi
  echo "GPG public keys exported locally for $EXPORT_EMAIL"

  # Base64 encode the pubkey for embedding in script
  PUBKEY_BASE64=$(base64 -w0 "$PUBKEY_FILE")
else
  PUBKEY_BASE64=""
fi

# Create the comprehensive remote script
cat > "$LOCAL_SCRIPT" << EOF
#!/bin/bash
set -euo pipefail

# Configuration
REMOTE_SOCAT_PID=""
CLEANUP_RAN=""
PUBKEY_FILE=""

# Function to check version requirements
app_version_lt_min() {
  local app_name=\$1
  local current_ver=\$2
  local min_ver=\$3

  if [[ "\$(echo -e "\$current_ver\n\$min_ver" | sort -rV | head -n 1)" != "\$current_ver" ]]; then
    echo "❌ ERROR: \$app_name version \$current_ver is older than minimum required version \$min_ver"
    echo "Please update \$app_name on the remote host"
    exit 1
  fi
}

# Function to check command availability
check_remote_cmd() {
  if ! command -v "\$1" &>/dev/null; then
    echo "❌ ERROR: \$1 is not installed on ${REMOTE_HOST}"
    echo "Please install it with your package manager on ${REMOTE_HOST}:"
    echo "  Ubuntu/Debian: sudo apt install \$2"
    echo "  Fedora: sudo dnf install \$2"
    echo "  Alpine: sudo apk add \$2"
    echo "  Arch: sudo pacman -S \$2"
    exit 1
  fi

  # Check version if version arguments are provided
  if [[ -n "\${3-}" && -n "\${4-}" ]]; then
    app_version_lt_min "\$1" "\$3" "\$4"
  fi
}

# Remote cleanup function
remote_cleanup() {
  # Save the original exit code that triggered this trap
  local exit_code=\$?

  # Prevent double execution
  if [ -n "\$CLEANUP_RAN" ]; then
    return \$exit_code
  fi
  CLEANUP_RAN=1

  echo "Cleaning remote resources"

  # Clean temporary files and GPG components
  if [ -n "\${PUBKEY_FILE:-}" ]; then
    rm -f "\$PUBKEY_FILE" 2>/dev/null || true
    gpgconf --kill gpg-agent 2>/dev/null || true
    gpgconf --kill keyboxd 2>/dev/null || true
  fi

  # Kill socat process
  if [ -n "\$REMOTE_SOCAT_PID" ]; then
    kill \$REMOTE_SOCAT_PID 2>/dev/null || true
  fi

  # Kill any other socat processes using a port-specific pattern
  pkill -f "socat.*gpg-agent.*localhost:${GPG_PORT}" 2>/dev/null || true

  echo "Remote GPG forwarding stopped"

  # Delete this script itself
  # param 0 reliable since calling this script with an absolute path in SSH command
  rm -f "\$0"

  # Use the original exit code
  exit \$exit_code
}

# Register remote cleanup for all exit scenarios
trap remote_cleanup EXIT INT TERM

# Check for required commands with version checks
echo "Checking remote dependencies"
check_remote_cmd gpg gpg "\$(gpg --version 2>/dev/null | head -n 1 | awk '{print \$3}')" "2.2.0"
check_remote_cmd socat socat

# Import keys if requested
${EXPORT_EMAIL:+# Import GPG keys
echo "Importing GPG keys for ${EXPORT_EMAIL}"

# Create temporary file for the public key
PUBKEY_FILE=\$(mktemp)

# Decode base64 pubkey
echo "${PUBKEY_BASE64}" | base64 -d > "\$PUBKEY_FILE"

# Launch keyboxd
if command -v gpgconf &>/dev/null; then
  # kill components as could be running in another session and lock the db
  gpgconf --kill gpg-agent 2>/dev/null || true
  gpgconf --kill keyboxd 2>/dev/null || true
  gpgconf --launch keyboxd 2>/dev/null || true
fi

# Import the public key
if ! gpg --import "\$PUBKEY_FILE"; then
  echo "❌ ERROR: Failed to import GPG public keys on remote host"
  exit 1
fi

# Verify key was imported
if ! gpg --list-keys | grep -q "\$(gpg --list-packets < "\$PUBKEY_FILE" | grep -i "keyid" | head -1 | awk '{print \$NF}')"; then
  echo "❌ ERROR: Could not verify GPG public keys were imported correctly"
  exit 1
fi

echo "✅ GPG public keys imported on ${REMOTE_HOST} for ${EXPORT_EMAIL}"
echo ""}

# Setup directories
mkdir -p ~/.gnupg /run/user/\$(id -u)/gnupg
chmod 700 ~/.gnupg /run/user/\$(id -u)/gnupg

# Kill any existing socat processes
pkill -f "socat.*gpg-agent.*localhost:${GPG_PORT}" || true

# Create a Unix socket that forwards to the TCP port
socat -d0 UNIX-LISTEN:/run/user/\$(id -u)/gnupg/S.gpg-agent,fork,unlink-early,mode=600 \\
    TCP:localhost:${GPG_PORT} &
REMOTE_SOCAT_PID=\$!

# Add no-autostart to gpg.conf if not already present
if ! grep -q "^no-autostart" ~/.gnupg/gpg.conf 2>/dev/null; then
  echo "no-autostart" >> ~/.gnupg/gpg.conf
  echo "Remote gpg.conf appended with 'no-autostart' to prevent starting its own gpg-agent"
fi

# Wait for socat socket to be ready
MAX_TRIES=10
echo "Waiting up to \$((MAX_TRIES / 2))s for gpg socket on $REMOTE_HOST to be ready"
for ((i=1; i<=\$MAX_TRIES; i++)); do
  if [ -S "/run/user/\$(id -u)/gnupg/S.gpg-agent" ]; then
    # GPG socket is ready
    break
  fi

  if [ \$i -eq \$MAX_TRIES ]; then
    echo "❌ ERROR: Socket not ready on $REMOTE_HOST after repeated attempts" >&2
    exit 1
  fi

  sleep 0.5s
done

# Verify GPG agent connection
GPG_AGENT_RESPONSE=\$(gpg-connect-agent --no-autostart "getinfo version" /bye)
if echo "\$GPG_AGENT_RESPONSE" | grep -q "OK"; then
  echo "✅ GPG agent forwarding to $REMOTE_HOST verified. You can use GPG with local private keys."
else
  echo "❌ ERROR: GPG agent forwarding to $REMOTE_HOST could not be verified" >&2
  exit 1
fi

echo ""
echo "Press Ctrl+C to stop forwarding and exit"

# Wait for socat to exit (or be killed)
wait \$REMOTE_SOCAT_PID
EOF

chmod +x "$LOCAL_SCRIPT"

# Print status
echo "Connect to $REMOTE_HOST and setup remote forwarding"

# Copy script to remote host with port-specific name
if ! scp -q "$LOCAL_SCRIPT" "$REMOTE_HOST:$REMOTE_SCRIPT"; then
  echo "❌ ERROR: Failed to transfer setup script to $REMOTE_HOST"
  exit 1
fi

# Kill any existing socat processes for the chosen port
pkill -f "socat.*${GPG_PORT}.*npiperelay.*gpg-agent" || true

# Start socat for main GPG agent socket - forward Windows socket to TCP port
# properly escape backslashes for socat
echo "Start npiperelay for local named pipe -> TCP socket"
SOCAT_ASSUAN_FILE=$(echo "$WIN_ASSUAN_FILE" | sed 's/\\/\\\\\\\\/g')
socat -d0 TCP4-LISTEN:${GPG_PORT},bind=localhost,fork,reuseaddr \
    EXEC:"npiperelay.exe -ei -ep -a \"${SOCAT_ASSUAN_FILE}\"" &
LOCAL_SOCAT_PID=$!

# Print status
# GPG Agent is now available via TCP at localhost
echo "Connect to $REMOTE_HOST and setup remote forwarding"

# Use ssh remote forwarding with additional options:
# -t: Force terminal allocation to ensure signals are properly forwarded
#     This pushes the local GPG port to the remote machine
if [ "$FORK_MODE" = true ]; then
  # not yet ready
  echo "❌ ERROR: Fork mode is not yet implemented"
  exit 1

  # Create log and pid files for the forked process with port-specific name
  LOG_FILE="/tmp/gpg-forward-${REMOTE_HOST}-${GPG_PORT}.log"
  PID_FILE="/tmp/gpg-forward-${REMOTE_HOST}-${GPG_PORT}.pid"

  # Launch SSH in background with port-specific script
  {
    ssh -t -R localhost:${GPG_PORT}:localhost:${GPG_PORT} "$REMOTE_HOST" "$REMOTE_SCRIPT" > "$LOG_FILE" 2>&1

    # kill remote socat with port-specific pattern even if remote script failed to do so
    ssh "$REMOTE_HOST" "pkill -f 'socat.*gpg-agent.*localhost:${GPG_PORT}'" >> "$LOG_FILE" 2>&1 || true

    echo "SSH connection closed" >> "$LOG_FILE"

    # TODO cleanup, remove pid file, etc.
  } &

  # Store PID in a file with port-specific name
  SSH_PID=$!
  echo $SSH_PID > "$PID_FILE"

  # Print status
  echo "Log file: $LOG_FILE"
  echo "PID file: $PID_FILE"
  echo "To terminate: kill $SSH_PID"
  echo "✅ GPG agent forwarding started in background (PID: $SSH_PID)"
  exit 0
fi

# non-forking behavior
# Temporarily disable the "exit on error" behavior
set +e
ssh -t -R localhost:${GPG_PORT}:localhost:${GPG_PORT} "$REMOTE_HOST" "$REMOTE_SCRIPT"
SSH_EXIT=$?
set -e

# Better handling of SSH errors vs. Ctrl+C
if [ $SSH_EXIT -eq 130 ]; then
  # SIGINT (Ctrl+C) - intentional user interruption
  echo "GPG forwarding stopped by user (SIGINT)"
  FINAL_EXIT=0
elif [ $SSH_EXIT -eq 255 ]; then
  # Check if our socat process is still running
  if kill -0 $LOCAL_SOCAT_PID 2>/dev/null; then
    # Our socat is still running, suggesting this wasn't a normal termination
    echo "❌ ERROR: SSH connection failed with code 255"
    echo "This may indicate network issues or authentication problems."
    FINAL_EXIT=255
  else
    # socat was terminated, suggesting normal termination via signal
    echo "GPG forwarding stopped (connection terminated)"
    FINAL_EXIT=0
  fi
else
  # Any other exit code
  echo "SSH connection closed with code $SSH_EXIT"
  FINAL_EXIT=$SSH_EXIT
fi

# kill remote socat with port-specific pattern even if remote script failed to do so
ssh "$REMOTE_HOST" "pkill -f 'socat.*gpg-agent.*localhost:${GPG_PORT}'" || true

# Exit with the appropriate code
exit $FINAL_EXIT

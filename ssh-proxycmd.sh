#!/usr/bin/env bash

# attempting to https://code.visualstudio.com/docs/remote/troubleshooting with ProxyCommand
# to automatically forward GPG agent to remote server when workspace is opened
# perhaps create entry in ~/.ssh/config
# Host vscode-gpg-myserver
#     HostName actual-server-address
#     User your-username
#     ProxyCommand ssh-proxycmd.sh %h %p   ???  and how relates to -W %h:%p

# Path to your GPG forwarding script, assume it's in the same directory
GPG_FORWARD="$(dirname "$0")/gpg-forward.sh"

# Get the remote host from arguments
REMOTE_HOST="$1"
shift

if [ -z "$REMOTE_HOST" ]; then
    echo "Usage: $0 <remote-host> [ssh-options]"
    exit 1
fi

# Launch GPG forwarding in the background
"$GPG_FORWARD" "$REMOTE_HOST" &
GPG_PID=$!

# Wait for GPG forwarding to be ready
sleep 5

# Connect with SSH (pass any additional arguments)
ssh "$REMOTE_HOST" "$@"

# After SSH connection ends, send SIGTERM to GPG forwarding process so it can cleanup
kill "$GPG_PID" 2>/dev/null

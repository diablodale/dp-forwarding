# GPG Forwarding from Windows to Remote Linux

GPG Forwarding is a secure and convenient tool that enables you to use your Windows-based GnuPG keys on remote Linux systems. It establishes a secure tunnel between your Windows GPG agent and remote Linux machines, allowing you to sign, encrypt, and decrypt files remotely without transferring your private keys.

## Features

- **Secure Key Forwarding**: Use your local Windows GPG keys on remote Linux systems without exposing private keys
- **Auto Port Selection**: Automatically finds an available port for forwarding
- **Public Key Export**: Option to export and import specific GPG public keys to remote systems
- **Intelligent Error Handling**: Properly handles network interruptions and user termination
- **Clean Cleanup**: Properly cleans up resources on both local and remote machines
- **Session Isolation**: Supports multiple simultaneous forwarding sessions with port-specific scripts

## Prerequisites

- Windows Subsystem for Linux 2 (WSL2)
- GnuPG installed and configured on both Windows and the remote Linux system
- `npiperelay.exe` for Windows named pipe access
- `socat` for socket forwarding
- `ssh` with remote port forwarding capabilities

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/gpg-forwarding.git
   cd gpg-forwarding
   ```

2. Make the script executable:
   ```bash
   chmod +x gpg-forward.sh
   ```

3. Ensure all dependencies are installed:
   ```bash
   # On Windows (using winget)
   winget install albertony.npiperelay

   # In WSL
   sudo apt install gnupg socat openssh-client
   ```

## Usage

### Basic Forwarding

```bash
./gpg-forward.sh <remote-host>
```

### Custom Port

By default, the script automatically selects an available port. You can specify a custom port if needed:

```bash
./gpg-forward.sh --port=12345 <remote-host>
```

### Export Public Key

To export and import your public key to the remote system:

```bash
./gpg-forward.sh --export=your@email.com <remote-host>
```

### Combined Options

```bash
./gpg-forward.sh --export=your@email.com --port=auto <remote-host>
```

## How It Works

GPG -> Unix socket -> socat -> TCP port -> SSH secure tunnel -> TCP port -> socat -> npiperelay -> Windows GPG agent

1. The script locates your Windows GPG agent socket
2. It uses `npiperelay.exe` and `socat` to create a TCP socket accessible from WSL
3. It creates a remote script with a unique port-specific name
4. It establishes an SSH connection with remote port forwarding
5. On the remote system, it creates a Unix socket that forwards to the TCP port
6. GPG on the remote system accesses this Unix socket
7. The script handles this forwarding process, including cleanup on termination

## Termination

To stop forwarding, simply press `Ctrl+C` in the terminal where the script is running. The script will automatically clean up resources on both local and remote systems.

## Troubleshooting

- **Port Conflicts**: If you receive port binding errors, try again, the default is to choose a random port.
  You can also use `--port=xxxxx` to specify your desired port.
- **Permission Issues**: Ensure your SSH user has proper permissions on the remote system
- **Authentication Failures**: Make sure your SSH keys are properly set up for the remote host
- **GPG Agent Not Found**: Verify that GPG is running in Windows and the agent socket exists

## License

This project is licensed under the Apache License 2.0. See the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [npiperelay](https://github.com/albertony/npiperelay) for providing Windows named pipe access
- [GnuPG](https://gnupg.org/) for the encryption software
- [socat](http://www.dest-unreach.org/socat/) for the socket forwarding capabilities

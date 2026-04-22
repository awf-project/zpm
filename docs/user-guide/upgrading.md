---
title: "Upgrading zpm"
---

Keep your zpm installation up to date with the `upgrade` command, which automatically downloads, verifies, and installs the latest release.

## Quick Start

Upgrade to the latest stable release:

```bash
zpm upgrade
```

The command downloads the binary for your platform, verifies its SHA256 checksum, and atomically replaces your running executable.

## Choosing a Release Channel

By default, `upgrade` pulls from the **stable** channel. For early access to new features, use **dev**:

```bash
# Stable releases (default, recommended for production)
zpm upgrade

# Development releases (includes prerelease versions)
zpm upgrade --channel dev
```

## Previewing an Upgrade

To see what version you'll get without modifying anything:

```bash
# See the target version and details
zpm upgrade --dry-run

# Preview a development channel upgrade
zpm upgrade --channel dev --dry-run
```

The output shows the target version, asset URL, expected checksum, and install path.

## Supported Platforms

Pre-built binaries are available for:

- Linux x86_64
- Linux ARM64 (aarch64)
- macOS (x86_64 and ARM64 in one universal binary)

If you're on an unsupported platform, the command will report an error with the list of available targets.

## Security

The upgrade command verifies the downloaded binary before installing it:

1. Downloads the `SHA256SUMS` file from the release
2. Computes SHA256 of the downloaded binary
3. Compares the computed hash against the published checksum
4. Only installs if hashes match exactly

This protects against man-in-the-middle attacks and corrupted downloads.

## Troubleshooting

**"Permission denied" error**

If your zpm binary is installed in a system directory (e.g., `/usr/local/bin`), you may need elevated privileges:

```bash
sudo zpm upgrade
```

**"Unsupported platform" error**

Your OS/architecture combination doesn't have a pre-built release. Install from source instead:

```bash
git clone https://github.com/awf-project/zpm.git
cd zpm
make build
# Binary is in zig-out/bin/zpm
```

**"ChecksumMismatch" error**

The downloaded binary failed verification. This usually indicates a network problem. Retry the upgrade:

```bash
zpm upgrade --dry-run  # Test connectivity
zpm upgrade            # Retry
```

## See Also

- [CLI Reference](../reference/cli.md#upgrade) — Detailed flags and exit codes
- [Getting Started](../getting-started/mcp-server.md) — Install zpm for the first time

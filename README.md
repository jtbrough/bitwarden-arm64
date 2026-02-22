# bitwarden-arm64

This project exists because official Bitwarden Linux ARM64 support is currently incomplete for common Linux distribution channels.

As of February 22, 2026, Bitwarden does not provide a complete first-party Linux ARM64 delivery story across key channels such as Homebrew, Flatpak, Snap, and AppImage.

This repository publishes community-built Linux ARM64 AppImages for Bitwarden Desktop and will continue doing so until Bitwarden provides formal, first-party Linux on ARM support.

## Scope

- Track upstream Bitwarden desktop releases from `bitwarden/clients`
- Rebuild ARM64 AppImages from official upstream release assets
- Publish releases with the same upstream tag (for example `desktop-v2026.1.1`)
- Include upstream changelog content and links back to the matching Bitwarden release

## Automation model

- GitHub Actions polls upstream releases on a schedule
- If a matching release tag does not already exist in this repo, CI builds and publishes it
- Manual workflow dispatch is available for specific versions

## Local build

Required dependencies:

- `bash`
- `curl`
- `jq`
- `tar`
- `file`
- `unsquashfs` and `mksquashfs` (usually from `squashfs-tools`)
- `grep`, `awk`, `sed`, `sha256sum`

Run:

```bash
./scripts/build.sh --version 2026.1.1
```

Output:

- `dist/Bitwarden-<version>-aarch64.AppImage`

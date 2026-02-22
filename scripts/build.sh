#!/usr/bin/env bash
set -euo pipefail

BITWARDEN_REPO="bitwarden/clients"
APPIMAGETOOL_URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-aarch64.AppImage"

WORK_DIR="${WORK_DIR:-$PWD/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/dist}"
VERSION=""
TAG=""
SKIP_VALIDATE=0

usage() {
  cat <<'USAGE'
Usage: scripts/build.sh [options]

Options:
  --version <version>      Build from a specific version (example: 2026.1.1)
  --tag <desktop-tag>      Build from a specific upstream tag (example: desktop-v2026.1.1)
  --work-dir <path>        Working directory (default: ./work)
  --output-dir <path>      Output directory (default: ./dist)
  --skip-validate          Skip output architecture checks
  -h, --help               Show help
USAGE
}

log() {
  printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

curl_json() {
  local url="$1"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "$url"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" "$url"
  fi
}

find_squashfs_offset() {
  local appimage="$1"
  local offsets
  offsets="$(grep -aob 'hsqs' "$appimage" | awk -F: '{print $1}')"
  [[ -n "$offsets" ]] || die "No SquashFS marker found in $appimage"

  local off
  while read -r off; do
    [[ -n "$off" ]] || continue
    if unsquashfs -s -offset "$off" "$appimage" >/dev/null 2>&1; then
      echo "$off"
      return 0
    fi
  done <<< "$offsets"

  die "No valid SquashFS offset found in $appimage"
}

download_file() {
  local url="$1"
  local out="$2"
  if [[ -s "$out" ]]; then
    log "Reusing $(basename "$out")"
    return 0
  fi
  log "Downloading $(basename "$out")"
  curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        VERSION="$2"
        shift 2
        ;;
      --tag)
        TAG="$2"
        shift 2
        ;;
      --work-dir)
        WORK_DIR="$2"
        shift 2
        ;;
      --output-dir)
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --skip-validate)
        SKIP_VALIDATE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

check_deps() {
  local -a deps=(curl jq tar file unsquashfs mksquashfs grep awk sed sha256sum)
  local d
  for d in "${deps[@]}"; do
    need_cmd "$d" || die "Missing required command: $d"
  done
}

main() {
  parse_args "$@"
  check_deps

  mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
  local release_json="$WORK_DIR/release.json"
  local download_dir="$WORK_DIR/downloads"
  local build_dir="$WORK_DIR/build"
  local tools_dir="$WORK_DIR/tools"
  mkdir -p "$download_dir" "$build_dir" "$tools_dir"

  local api_url
  if [[ -n "$TAG" ]]; then
    api_url="https://api.github.com/repos/${BITWARDEN_REPO}/releases/tags/${TAG}"
  elif [[ -n "$VERSION" ]]; then
    api_url="https://api.github.com/repos/${BITWARDEN_REPO}/releases/tags/desktop-v${VERSION}"
  else
    api_url="https://api.github.com/repos/${BITWARDEN_REPO}/releases/latest"
  fi

  log "Fetching release metadata"
  curl_json "$api_url" > "$release_json"

  local release_tag
  release_tag="$(jq -r '.tag_name' "$release_json")"
  [[ -n "$release_tag" && "$release_tag" != "null" ]] || die "Could not parse release tag"

  local x64_name x64_url arm_name arm_url version
  x64_name="$(jq -r '.assets[] | select(.name | test("^Bitwarden-[0-9.]+-x86_64\\.AppImage$")) | .name' "$release_json" | head -n1)"
  x64_url="$(jq -r '.assets[] | select(.name | test("^Bitwarden-[0-9.]+-x86_64\\.AppImage$")) | .browser_download_url' "$release_json" | head -n1)"
  arm_name="$(jq -r '.assets[] | select(.name | test("^bitwarden_[0-9.]+_arm64\\.tar\\.gz$")) | .name' "$release_json" | head -n1)"
  arm_url="$(jq -r '.assets[] | select(.name | test("^bitwarden_[0-9.]+_arm64\\.tar\\.gz$")) | .browser_download_url' "$release_json" | head -n1)"

  [[ -n "$x64_url" && -n "$arm_url" ]] || die "Required assets not found in ${release_tag}"

  version="$(sed -E 's/^Bitwarden-([0-9.]+)-x86_64\.AppImage$/\1/' <<< "$x64_name")"
  log "Upstream release: ${release_tag}"
  log "Resolved version: ${version}"

  local x64_path="$download_dir/$x64_name"
  local arm_path="$download_dir/$arm_name"
  local appimagetool="$tools_dir/appimagetool-aarch64.AppImage"

  download_file "$x64_url" "$x64_path"
  download_file "$arm_url" "$arm_path"
  download_file "$APPIMAGETOOL_URL" "$appimagetool"
  chmod +x "$appimagetool"

  rm -rf "$build_dir/AppDir" "$build_dir/arm" "$build_dir/verify"
  mkdir -p "$build_dir/arm"

  local offset
  offset="$(find_squashfs_offset "$x64_path")"
  log "Extracting AppDir from x64 AppImage (offset ${offset})"
  unsquashfs -d "$build_dir/AppDir" -offset "$offset" "$x64_path" >/dev/null

  log "Extracting arm64 tarball"
  tar -xzf "$arm_path" -C "$build_dir/arm"

  log "Overlaying arm64 payload"
  cp -a "$build_dir/arm/." "$build_dir/AppDir/."
  chmod +x "$build_dir/AppDir/AppRun" "$build_dir/AppDir/bitwarden" "$build_dir/AppDir/bitwarden-app"

  local out_appimage="$OUTPUT_DIR/Bitwarden-${version}-aarch64.AppImage"
  log "Building output AppImage"
  env ARCH=arm_aarch64 APPIMAGE_EXTRACT_AND_RUN=1 \
    "$appimagetool" "$build_dir/AppDir" "$out_appimage" >/dev/null
  chmod +x "$out_appimage"

  if [[ "$SKIP_VALIDATE" -eq 0 ]]; then
    log "Validating output"
    file "$out_appimage" | grep -qi 'ARM aarch64' || die "Output is not ARM aarch64"
    local out_offset
    out_offset="$($out_appimage --appimage-offset)"
    unsquashfs -no-xattrs -d "$build_dir/verify" -offset "$out_offset" "$out_appimage" >/dev/null
    file "$build_dir/verify/bitwarden-app" | grep -qi 'ARM aarch64' || die "Embedded bitwarden-app is not ARM aarch64"
  fi

  local sha
  sha="$(sha256sum "$out_appimage" | awk '{print $1}')"
  echo "OUT_APPIMAGE=$out_appimage" > "$WORK_DIR/build.env"
  echo "UPSTREAM_TAG=$release_tag" >> "$WORK_DIR/build.env"
  echo "UPSTREAM_VERSION=$version" >> "$WORK_DIR/build.env"
  echo "OUT_SHA256=$sha" >> "$WORK_DIR/build.env"

  log "Done"
  printf 'Output: %s\nSHA256: %s\nTag: %s\n' "$out_appimage" "$sha" "$release_tag"
}

main "$@"

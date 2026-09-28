#!/usr/bin/env bash
# =============================================================================
# fileflows-manage
#
# Installs, updates and rolls back FileFlows Server inside an existing
# Debian 12 (bookworm) or Debian 13 (trixie) container, with Intel iGPU
# support for QSV/VAAPI encoding and OpenCL (HDR tone mapping).
#
# Run INSIDE the container as root:
#     bash fileflows-manage.sh install      # first install; copies itself to
#                                           # /usr/local/sbin/fileflows-manage
#     fileflows-manage update               # show versions, confirm, update
#     fileflows-manage rollback             # restore the newest backup
#     fileflows-manage status               # versions, service, GPU, backups
#     fileflows-manage gputest              # QSV / VAAPI / OpenCL checks
#
# -----------------------------------------------------------------------------
# Recommended container (create it however you normally do)
# -----------------------------------------------------------------------------
#   Template   : Debian 12 standard (Debian 13 also works, minus OpenCL)
#   Type       : Unprivileged, nesting=1
#   CPU / RAM  : 4 cores / 4 GiB (2 / 2 works; ffmpeg still uses CPU for
#                demux, audio and muxing even with GPU encoding)
#   Swap       : 512 MiB
#   Root disk  : 32 GiB. In-progress encodes are written to the container's
#                temp dir, roughly 1-2x the source file per active runner.
#   GPU        : Pass /dev/dri/renderD128 via Proxmox device passthrough, e.g.
#                  pct set <CTID> --dev0 /dev/dri/renderD128,gid=<render GID in CT>
#                Get the GID inside the CT with: getent group render
#   Media      : Optional bind mount (mp0). In an unprivileged CT, files written
#                by container root appear on the host as UID 100000, so the
#                host path must be writable by that UID.
#
# -----------------------------------------------------------------------------
# What this installs and where
# -----------------------------------------------------------------------------
#   /opt/fileflows                 FileFlows app + Data (database, config)
#   /opt/fileflows-backups         tar.gz backups taken before every update
#   /usr/lib/jellyfin-ffmpeg       FFmpeg with its own bundled Intel iHD
#                                  VAAPI/QSV driver (Jellyfin apt repo)
#   /usr/local/bin/ffmpeg,ffprobe  symlinks to the above
#   intel-opencl-icd               Intel OpenCL runtime from Debian's own repo.
#                                  Debian 12's build supports Gen9 (UHD 630);
#                                  Intel's current GitHub builds do not.
#   aspnetcore-runtime-<N>.0       .NET version FileFlows declares it needs
#                                  (Microsoft apt repo)
#   Optional (prompted)            System iHD driver + vainfo from Debian
#                                  non-free, for other tools in this CT.
#                                  jellyfin-ffmpeg does not need it.
#
# -----------------------------------------------------------------------------
# Update model
# -----------------------------------------------------------------------------
#   apt upgrade           keeps .NET, FFmpeg, Intel drivers and Debian patched
#   fileflows-manage update  updates FileFlows itself (not an apt package).
#     1. Downloads the package to a staging folder (nothing changes yet).
#     2. Reads the version from the downloaded files and shows it next to the
#        installed version, plus the download URL and SHA-256.
#     3. Asks before doing anything. Refuses same-version and downgrades
#        unless FORCE=1. Warns if files are mid-processing.
#     4. Stops FileFlows, backs up the whole install (app + Data), installs
#        any newer .NET runtime the new version needs, swaps files, starts.
#   FileFlows migrates its database on first start of a new version, so going
#   back means restoring the backup: fileflows-manage rollback
#
# Environment overrides:
#   FF_URL=<url>         package URL (default: official tar.xz download)
#   FF_PACKAGE=<file>    install/update from a local package file instead
#   ASSUME_YES=1         answer "yes" to update/install confirmations
#   FORCE=1              allow reinstalling the same version or downgrading
#   INSTALL_SYSTEM_VAAPI=yes|no   skip the optional-driver prompt
#   KEEP_BACKUPS=3       number of update backups to keep
# =============================================================================

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

INSTALL_DIR="${INSTALL_DIR:-/opt/fileflows}"
BACKUP_DIR="${BACKUP_DIR:-/opt/fileflows-backups}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
FF_URL="${FF_URL:-https://fileflows.com/downloads/tarxz}"
FF_PACKAGE="${FF_PACKAGE:-}"
PORT="${PORT:-19200}"
ASSUME_YES="${ASSUME_YES:-0}"
FORCE="${FORCE:-0}"
INSTALL_SYSTEM_VAAPI="${INSTALL_SYSTEM_VAAPI:-ask}"

FFMPEG_DIR=/usr/lib/jellyfin-ffmpeg
SELF_PATH=/usr/local/sbin/fileflows-manage
SERVER_DLL="${INSTALL_DIR}/Server/FileFlows.Server.dll"
VERSION_FILE="${INSTALL_DIR}/.installed-version"
RELEASE_NOTES="https://fileflows.com/docs/versions"

# Colors for the completion summary
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
NC='\e[0m'

# Filled in during install so the summary reports what actually happened
OPENCL_STATUS="not installed"
VAAPI_STATUS="not installed (jellyfin-ffmpeg uses its own bundled copy)"

STAGE_ROOT=""
STAGE=""
PKG_VERSION=""
PKG_DOTNET=""
PKG_SOURCE=""
PKG_SHA256=""

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
msg()  { echo -e "\e[1;34m[fileflows]\e[0m $*"; }
warn() { echo -e "\e[1;33m[fileflows]\e[0m $*" >&2; }
die()  { echo -e "\e[1;31m[fileflows]\e[0m $*" >&2; exit 1; }

cleanup() { [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" ]] && rm -rf "$STAGE_ROOT"; return 0; }
trap cleanup EXIT
trap 'die "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

# Yes/no prompt, default No. Reads from the terminal so it still works if the
# script itself was piped in. With no terminal, the answer is No.
confirm() {
  if [[ "$ASSUME_YES" == "1" ]]; then return 0; fi
  local reply=""
  if ! { read -r -p "$1 [y/N]: " reply </dev/tty; } 2>/dev/null; then
    return 1
  fi
  [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

need_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }

# Supported: Debian 12 and 13. Sets OS_VERSION_ID and OS_CODENAME.
check_os() {
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:12|debian:13) ;;
    *) die "Expected Debian 12 or 13; found ${PRETTY_NAME:-unknown}." ;;
  esac
  OS_VERSION_ID="$VERSION_ID"
  OS_CODENAME="$VERSION_CODENAME"
}

render_node() { find /dev/dri -maxdepth 1 -name 'renderD*' 2>/dev/null | sort | head -n1 || true; }

# Read the version baked into a .NET assembly without running it. .NET
# assemblies carry a Windows-style version resource with UTF-16 strings
# "FileVersion" / "ProductVersion" followed by the value.
dll_version() {
  local f="$1" v=""
  [[ -f "$f" ]] || return 0
  v="$(strings -el "$f" 2>/dev/null | grep -A1 -x -m1 'FileVersion' | tail -n1 || true)"
  if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    v="$(strings -el "$f" 2>/dev/null | grep -A1 -x -m1 'ProductVersion' | tail -n1 || true)"
    v="${v%%+*}"
  fi
  if [[ "$v" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then echo "$v"; fi
}

installed_version() {
  local v
  v="$(dll_version "$SERVER_DLL")"
  if [[ -z "$v" && -f "$VERSION_FILE" ]]; then v="$(<"$VERSION_FILE")"; fi
  echo "$v"
}

# .NET major version a FileFlows build targets, from its runtimeconfig.json.
dotnet_major_of() {
  local cfg="$1" major=""
  if [[ -f "$cfg" ]]; then
    major="$(jq -r '
      [ .runtimeOptions.framework.version?,
        (.runtimeOptions.frameworks[]?.version) ]
      | map(select(. != null)) | first // empty' "$cfg" | cut -d. -f1)"
  fi
  [[ "$major" =~ ^[0-9]+$ ]] || major=10
  echo "$major"
}

has_aspnet_runtime() {
  command -v dotnet >/dev/null \
    && dotnet --list-runtimes 2>/dev/null | grep -q "^Microsoft.AspNetCore.App $1\."
}

# -----------------------------------------------------------------------------
# Packages and repositories
# -----------------------------------------------------------------------------
install_base_packages() {
  msg "Installing base tools"
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl gpg file unzip xz-utils jq binutils procps
}

# Microsoft's documented method for Debian: their release package sets up the
# repo and signing key for this exact Debian version.
add_microsoft_repo() {
  if dpkg -s packages-microsoft-prod >/dev/null 2>&1; then return 0; fi
  msg "Adding Microsoft package repo for Debian ${OS_VERSION_ID}"
  local deb
  deb="$(mktemp --suffix=.deb)"
  curl -fsSL -o "$deb" \
    "https://packages.microsoft.com/config/debian/${OS_VERSION_ID}/packages-microsoft-prod.deb"
  dpkg -i "$deb"
  rm -f "$deb"
}

# Jellyfin's repo, with a keyring that only signs this repo.
add_jellyfin_repo() {
  if [[ -f /etc/apt/sources.list.d/jellyfin.sources ]]; then return 0; fi
  msg "Adding Jellyfin repo (jellyfin-ffmpeg)"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/jellyfin.gpg
  cat >/etc/apt/sources.list.d/jellyfin.sources <<EOF
Types: deb
URIs: https://repo.jellyfin.org/debian
Suites: ${OS_CODENAME}
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/jellyfin.gpg
EOF
}

# FFmpeg for encoding. jellyfin-ffmpeg ships its own Intel iHD driver and QSV
# runtime in /usr/lib/jellyfin-ffmpeg/lib and loads that copy first.
install_ffmpeg() {
  msg "Installing jellyfin-ffmpeg7"
  apt-get install -y jellyfin-ffmpeg7
  ln -sf "${FFMPEG_DIR}/ffmpeg"  /usr/local/bin/ffmpeg
  ln -sf "${FFMPEG_DIR}/ffprobe" /usr/local/bin/ffprobe
}

# OpenCL runtime for HDR tone mapping. Uses Debian's package on purpose:
# Intel moved Gen8/9/11 GPUs (incl. UHD 630) to separate "legacy1" builds, so
# grabbing the newest release from GitHub gives a runtime that ignores them.
install_opencl() {
  if apt-cache show intel-opencl-icd >/dev/null 2>&1; then
    msg "Installing Intel OpenCL runtime (intel-opencl-icd from Debian)"
    apt-get install -y intel-opencl-icd
    OPENCL_STATUS="intel-opencl-icd $(dpkg-query -W -f='${Version}' intel-opencl-icd 2>/dev/null || true)"
  else
    warn "intel-opencl-icd is not in the Debian ${OS_CODENAME} repos; skipping OpenCL."
    warn "Encoding is unaffected; only OpenCL-based HDR tone mapping is unavailable."
  fi
}

# Optional: Debian's own iHD VAAPI driver + vainfo (non-free component).
# Not used by jellyfin-ffmpeg; useful only if other tools in this CT need it.
maybe_install_system_vaapi() {
  local choice="$INSTALL_SYSTEM_VAAPI"
  if [[ "$choice" == "ask" ]]; then
    if [[ "$ASSUME_YES" == "1" ]]; then
      choice="no"
    else
      echo
      echo "  jellyfin-ffmpeg already includes the Intel iHD driver it uses."
      echo "  Debian's copy (intel-media-va-driver-non-free + vainfo) is only"
      echo "  needed if other programs in this container use VAAPI."
      if confirm "  Install the system Intel VAAPI driver as well?"; then
        choice="yes"
      else
        choice="no"
      fi
    fi
  fi
  [[ "$choice" == "yes" ]] || return 0

  if ! apt-cache show intel-media-va-driver-non-free >/dev/null 2>&1; then
    msg "Enabling Debian non-free component for the Intel driver"
    cat >/etc/apt/sources.list.d/debian-non-free.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${OS_CODENAME} ${OS_CODENAME}-updates
Components: non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    apt-get update
  fi
  apt-get install -y intel-media-va-driver-non-free vainfo
  VAAPI_STATUS="intel-media-va-driver-non-free + vainfo installed"
}

# Install the ASP.NET Core runtime major version a FileFlows build needs.
ensure_dotnet() {
  local major="$1"
  if has_aspnet_runtime "$major"; then
    msg "ASP.NET Core ${major} runtime present"
    return 0
  fi
  add_microsoft_repo
  apt-get update
  msg "Installing aspnetcore-runtime-${major}.0"
  apt-get install -y "aspnetcore-runtime-${major}.0"
}

# -----------------------------------------------------------------------------
# FileFlows package handling
# -----------------------------------------------------------------------------
# Download (or copy) the package into a staging folder and read its version.
# Nothing in /opt/fileflows is touched here.
fetch_package() {
  STAGE_ROOT="$(mktemp -d /var/tmp/fileflows-stage.XXXXXX)"
  local pkg="${STAGE_ROOT}/package" mime sub

  if [[ -n "$FF_PACKAGE" ]]; then
    [[ -f "$FF_PACKAGE" ]] || die "FF_PACKAGE ${FF_PACKAGE} not found."
    cp "$FF_PACKAGE" "$pkg"
    PKG_SOURCE="$FF_PACKAGE (local file)"
  else
    msg "Downloading ${FF_URL}"
    PKG_SOURCE="$(curl -fL --retry 3 -o "$pkg" -w '%{url_effective}' "$FF_URL")"
  fi
  PKG_SHA256="$(sha256sum "$pkg" | cut -d' ' -f1)"

  mime="$(file -b --mime-type "$pkg")"
  mkdir -p "${STAGE_ROOT}/x"
  case "$mime" in
    application/x-xz) tar -xJf "$pkg" -C "${STAGE_ROOT}/x" ;;
    application/gzip) tar -xzf "$pkg" -C "${STAGE_ROOT}/x" ;;
    application/zip)  unzip -q "$pkg" -d "${STAGE_ROOT}/x" ;;
    *) die "Unexpected package type: ${mime}" ;;
  esac

  # Some archives wrap everything in one folder; step into it if so.
  STAGE="${STAGE_ROOT}/x"
  if [[ ! -d "${STAGE}/Server" ]]; then
    sub="$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    if [[ -n "$sub" && -d "${sub}/Server" ]]; then STAGE="$sub"; fi
  fi
  [[ -f "${STAGE}/Server/FileFlows.Server.dll" ]] \
    || die "Package layout unexpected: Server/FileFlows.Server.dll not found."

  PKG_VERSION="$(dll_version "${STAGE}/Server/FileFlows.Server.dll")"
  PKG_DOTNET="$(dotnet_major_of "${STAGE}/Server/FileFlows.Server.runtimeconfig.json")"
}

# Print what is installed vs what would be installed.
show_plan() {
  local cur="$1" dotnet_note
  if has_aspnet_runtime "$PKG_DOTNET"; then
    dotnet_note="installed"
  else
    dotnet_note="not installed, will add aspnetcore-runtime-${PKG_DOTNET}.0"
  fi
  echo
  echo "  Installed version : ${cur:-not installed}"
  echo "  Proposed version  : ${PKG_VERSION:-unknown (could not read from package)}"
  echo "  Downloaded from   : ${PKG_SOURCE}"
  echo "  Package SHA-256   : ${PKG_SHA256}"
  echo "  Needs .NET        : ${PKG_DOTNET} (${dotnet_note})"
  echo "  Release notes     : ${RELEASE_NOTES}"
  echo
}

# Copy the staged app over the install dir. Data/ is never touched. Each
# top-level folder shipped in the package replaces the old one entirely, so
# stale files from previous versions don't linger.
swap_in() {
  local entry name
  install -d -m 0755 "$INSTALL_DIR"
  for entry in "${STAGE}"/*; do
    name="$(basename "$entry")"
    if [[ "$name" == "Data" ]]; then continue; fi
    rm -rf "${INSTALL_DIR:?}/${name}"
    cp -a "$entry" "${INSTALL_DIR}/"
  done
  if [[ -n "$PKG_VERSION" ]]; then echo "$PKG_VERSION" >"$VERSION_FILE"; fi
}

# True if a FileFlows flow runner (a file being processed) is running.
flows_running() { pgrep -f 'FlowRunner' >/dev/null 2>&1; }

# Full backup of app + Data (logs excluded). Taken with the service stopped
# so the SQLite database is consistent.
backup_current() {
  local cur ts
  cur="$(installed_version)"; cur="${cur:-unknown}"
  ts="$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$BACKUP_DIR"
  BACKUP_FILE="${BACKUP_DIR}/fileflows_${cur}_${ts}.tar.gz"
  msg "Backing up ${INSTALL_DIR} to ${BACKUP_FILE}"
  tar -C "$(dirname "$INSTALL_DIR")" --exclude='*/Logs' \
    -czf "$BACKUP_FILE" "$(basename "$INSTALL_DIR")"

  # Keep only the newest KEEP_BACKUPS archives.
  find "$BACKUP_DIR" -maxdepth 1 -name 'fileflows_*.tar.gz' -printf '%T@ %p\n' \
    | sort -rn | tail -n +"$((KEEP_BACKUPS + 1))" | cut -d' ' -f2- | xargs -r rm -f
}

install_service() {
  msg "Registering the FileFlows systemd service"
  # FileFlows' documented installer. "--root true" runs it as root inside the
  # container; in an unprivileged CT that maps to UID 100000 on the host.
  ( cd "${INSTALL_DIR}/Server" && dotnet FileFlows.Server.dll --systemd install --root true )
  systemctl daemon-reload
  systemctl enable --now fileflows
}

wait_for_web() {
  for _ in $(seq 1 60); do
    if curl -fs -o /dev/null "http://localhost:${PORT}"; then
      msg "Web UI is up on port ${PORT}"
      return 0
    fi
    sleep 2
  done
  warn "Web UI not answering on port ${PORT}. Check: journalctl -u fileflows -n 100"
}

# Copy this script to /usr/local/sbin so updates run the same reviewed code.
install_self() {
  local src
  src="$(readlink -f "$0" 2>/dev/null || true)"
  if [[ -f "$src" && "$src" != "$SELF_PATH" ]]; then
    install -m 0755 "$src" "$SELF_PATH"
    msg "Installed ${SELF_PATH}"
  elif [[ ! -f "$src" ]]; then
    warn "Could not locate this script on disk; copy it to ${SELF_PATH} manually."
  fi
}

# Container's first global IPv4 address (same approach as your other scripts),
# falling back to hostname -I if the ip tool is missing.
container_ip() {
  local ip=""
  if command -v ip >/dev/null; then
    ip="$(ip -4 addr show scope global | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1 || true)"
  fi
  if [[ -z "$ip" ]]; then ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"; fi
  echo "${ip:-<container-ip>}"
}

# FileFlows serves its web console at the root path on port 19200 (its
# default since 24.03; there is no /web suffix like Plex).
print_access() {
  echo -e "${GREEN}Access FileFlows at:${NC}"
  echo "  http://$(container_ip):${PORT}/"
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
cmd_install() {
  need_root
  check_os
  if [[ -f "$SERVER_DLL" ]]; then
    die "FileFlows is already installed in ${INSTALL_DIR}. Use: fileflows-manage update"
  fi
  if [[ -z "$(render_node)" ]]; then
    warn "No /dev/dri/renderD* in this container. GPU passthrough isn't set up;"
    warn "FileFlows will fall back to CPU encoding until it is."
  fi

  install_base_packages
  fetch_package
  show_plan ""
  confirm "Install FileFlows ${PKG_VERSION:-(unknown version)}?" \
    || { msg "Aborted. Only base tools were installed."; exit 0; }

  add_microsoft_repo
  add_jellyfin_repo
  apt-get update
  install_ffmpeg
  install_opencl
  maybe_install_system_vaapi
  ensure_dotnet "$PKG_DOTNET"

  swap_in
  install_service
  wait_for_web
  install_self
  cmd_gputest

  local svc
  svc="$(systemctl is-active fileflows 2>/dev/null || true)"
  echo
  echo -e "${GREEN}=== Installation Complete ===${NC}"
  echo "• FileFlows ${PKG_VERSION:-(version unknown)} installed to ${INSTALL_DIR}"
  echo "• systemd service 'fileflows' enabled (currently: ${svc:-unknown})"
  echo "• ASP.NET Core ${PKG_DOTNET} runtime (Microsoft repo)"
  echo "• jellyfin-ffmpeg7 at ${FFMPEG_DIR} (symlinked to /usr/local/bin)"
  echo "• OpenCL: ${OPENCL_STATUS}"
  echo "• System VAAPI driver: ${VAAPI_STATUS}"
  echo "• Management script: ${SELF_PATH}"
  echo
  print_access
  echo
  echo -e "${YELLOW}First visit:${NC}"
  echo "  • The initial configuration wizard runs first (includes accepting the EULA)."
  echo "  • Under Variables, set ffmpeg to ${FFMPEG_DIR}/ffmpeg"
  echo "    (and ffprobe to ${FFMPEG_DIR}/ffprobe if it isn't picked up)."
  echo
  echo "Later: 'apt update && apt upgrade' for system packages,"
  echo "       'fileflows-manage update' for FileFlows itself."
}

cmd_update() {
  need_root
  check_os
  [[ -f "$SERVER_DLL" ]] || die "FileFlows is not installed. Use: fileflows-manage install"
  local tool
  for tool in curl file jq strings xz pgrep; do
    if ! command -v "$tool" >/dev/null; then install_base_packages; break; fi
  done

  local cur
  cur="$(installed_version)"
  fetch_package
  show_plan "$cur"

  # Same-version and downgrade guards.
  if [[ -n "$cur" && -n "$PKG_VERSION" ]]; then
    if dpkg --compare-versions "$PKG_VERSION" eq "$cur" && [[ "$FORCE" != "1" ]]; then
      msg "Already on ${cur}. Nothing to do. (FORCE=1 reinstalls it.)"
      exit 0
    fi
    if dpkg --compare-versions "$PKG_VERSION" lt "$cur"; then
      warn "The proposed version is OLDER than what's installed."
      warn "The database was migrated by ${cur}; use 'fileflows-manage rollback' instead."
      [[ "$FORCE" == "1" ]] || die "Refusing to downgrade without FORCE=1."
    fi
  else
    warn "Could not compare versions; check them above before continuing."
  fi

  if flows_running; then
    warn "Files are currently being processed. Updating stops FileFlows and"
    warn "aborts them. Pause processing in the web UI first if that matters."
  fi

  confirm "Update FileFlows ${cur:-?} -> ${PKG_VERSION:-?}?" \
    || { msg "Aborted. Nothing was changed."; exit 0; }

  msg "Stopping FileFlows"
  systemctl stop 'fileflows*'
  backup_current
  ensure_dotnet "$PKG_DOTNET"
  swap_in
  msg "Starting FileFlows"
  systemctl start fileflows
  wait_for_web
  echo
  echo -e "${GREEN}=== Update Complete ===${NC}"
  echo "• FileFlows ${cur:-?} -> ${PKG_VERSION:-?}"
  echo "• Backup: ${BACKUP_FILE}"
  echo "• To undo: fileflows-manage rollback"
  echo
  print_access
}

# Restore the newest backup (or the file given as $1): app files and Data.
cmd_rollback() {
  need_root
  local backup="${1:-}" cur bver ts
  if [[ -z "$backup" ]]; then
    backup="$(find "$BACKUP_DIR" -maxdepth 1 -name 'fileflows_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | head -n1 | cut -d' ' -f2- || true)"
  fi
  [[ -n "$backup" && -f "$backup" ]] || die "No backup found in ${BACKUP_DIR}."

  cur="$(installed_version)"
  bver="$(basename "$backup" | sed -E 's/^fileflows_(.*)_[0-9]{8}-[0-9]{6}\.tar\.gz$/\1/')"
  echo
  echo "  Installed version : ${cur:-unknown}"
  echo "  Restore to        : ${bver} (app + database as they were before that update)"
  echo "  From backup       : ${backup}"
  echo
  confirm "Roll back?" || { msg "Aborted. Nothing was changed."; exit 0; }

  ts="$(date +%Y%m%d-%H%M%S)"
  systemctl stop 'fileflows*' || true
  mv "$INSTALL_DIR" "${INSTALL_DIR}.pre-rollback-${ts}"
  tar -C "$(dirname "$INSTALL_DIR")" -xzf "$backup"
  ensure_dotnet "$(dotnet_major_of "${INSTALL_DIR}/Server/FileFlows.Server.runtimeconfig.json")"
  systemctl start fileflows
  wait_for_web
  echo
  echo -e "${GREEN}=== Rollback Complete ===${NC}"
  echo "• FileFlows restored to ${bver}"
  echo "• Replaced install kept at ${INSTALL_DIR}.pre-rollback-${ts} (delete once you're happy)"
  echo
  print_access
}

cmd_status() {
  local node
  echo "FileFlows version : $(installed_version || true)"
  echo "Service           : $(systemctl is-active fileflows 2>/dev/null || true)"
  echo "Web console       : http://$(container_ip):${PORT}/"
  local busy=no
  if flows_running; then busy=yes; fi
  echo "Processing now    : ${busy}"
  echo ".NET runtimes     :"
  (dotnet --list-runtimes 2>/dev/null | grep AspNetCore | sed 's/^/                    /') || echo "                    none"
  echo "FFmpeg            : $("${FFMPEG_DIR}/ffmpeg" -hide_banner -version 2>/dev/null | head -n1 || echo missing)"
  node="$(render_node)"
  echo "Render node       : ${node:-none (GPU not passed through)}"
  echo "OpenCL ICDs       : $(find /etc/OpenCL/vendors -name '*.icd' -printf '%f ' 2>/dev/null || true)"
  echo "Backups           :"
  find "$BACKUP_DIR" -maxdepth 1 -name 'fileflows_*.tar.gz' -printf '                    %f\n' 2>/dev/null | sort -r || true
}

# Hardware checks. All non-fatal: FileFlows tries QSV, then VAAPI, then CPU.
cmd_gputest() {
  local node ff="${FFMPEG_DIR}/ffmpeg"
  node="$(render_node)"
  [[ -x "$ff" ]] || { warn "jellyfin-ffmpeg not installed."; return 0; }
  [[ -n "$node" ]] || { warn "No render node in this container; skipping GPU tests."; return 0; }
  msg "Render node: ${node}"

  "${FFMPEG_DIR}/vainfo" --display drm --device "$node" 2>/dev/null \
    | grep -E 'Driver version|VAProfileHEVCMain' || warn "vainfo returned nothing useful"

  run_test() { # $1 label, rest = ffmpeg args
    local label="$1"; shift
    if "$ff" -hide_banner -loglevel error "$@" -f null - >/dev/null 2>&1; then
      msg "${label}: OK"
    else
      warn "${label}: FAILED"
    fi
  }
  local src=(-f lavfi -i testsrc2=size=1920x1080:rate=30 -t 3)

  run_test "QSV   HEVC 8-bit " -init_hw_device "vaapi=va:${node}" -init_hw_device qsv=qs@va \
    -filter_hw_device qs "${src[@]}" -vf 'format=nv12,hwupload=extra_hw_frames=64' -c:v hevc_qsv
  run_test "QSV   HEVC 10-bit" -init_hw_device "vaapi=va:${node}" -init_hw_device qsv=qs@va \
    -filter_hw_device qs "${src[@]}" -vf 'format=p010le,hwupload=extra_hw_frames=64' \
    -c:v hevc_qsv -profile:v main10
  run_test "VAAPI HEVC 8-bit " -init_hw_device "vaapi=va:${node}" -filter_hw_device va \
    "${src[@]}" -vf 'format=nv12,hwupload' -c:v hevc_vaapi
  run_test "VAAPI HEVC 10-bit" -init_hw_device "vaapi=va:${node}" -filter_hw_device va \
    "${src[@]}" -vf 'format=p010,hwupload' -c:v hevc_vaapi -profile:v main10
  run_test "OpenCL (tone map)" -init_hw_device "vaapi=va:${node}" -init_hw_device opencl=ocl@va \
    -f lavfi -i testsrc2=size=320x240 -frames:v 1
}

usage() {
  sed -n '2,16p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
  exit 1
}

case "${1:-}" in
  install)  cmd_install ;;
  update)   cmd_update ;;
  rollback) shift; cmd_rollback "${1:-}" ;;
  status)   cmd_status ;;
  gputest)  cmd_gputest ;;
  *)        usage ;;
esac

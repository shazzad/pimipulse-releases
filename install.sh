#!/usr/bin/env bash
# PimiPulse agent installer: enrol, upgrade or remove the agent on a Linux box with systemd.
#
#   Enrol:    curl -fsSL https://raw.githubusercontent.com/shazzad/pimipulse-releases/main/install.sh \
#               | sudo bash -s -- --endpoint https://pulse.example.com --code pp_enr_...
#   Upgrade:  curl -fsSL https://raw.githubusercontent.com/shazzad/pimipulse-releases/main/install.sh | sudo bash
#   Remove:   curl -fsSL https://raw.githubusercontent.com/shazzad/pimipulse-releases/main/install.sh | sudo bash -s -- --uninstall
#
# Options:
#   --version X.Y.Z   install that release instead of the latest one
#   --re-enrol        enrol again on a box that is already enrolled (needs --endpoint and --code)
#   --dry-run         download and verify only, then print what a real run would do (no root needed)
#
# The source of this file is deploy/install.sh in shazzad/pimipulse-agent; bin/release copies it to
# the public releases repo. The systemd unit below is a copy of deploy/pimipulse-agent.service so the
# one-liner needs no second file; bin/release refuses to release if the two differ.
set -euo pipefail

RELEASES="https://github.com/shazzad/pimipulse-releases/releases"
BIN=/usr/local/bin/pimipulse-agent
UNIT=/etc/systemd/system/pimipulse-agent.service
DROPIN_DIR=/etc/systemd/system/pimipulse-agent.service.d
STATE_DIR=/var/lib/pimipulse

ENDPOINT=""
CODE=""
VERSION=""
REENROL=0
DRY_RUN=0
UNINSTALL=0
ARCH=""
WORK=""
DOWNLOADED=""
BIN_VERSION=""

say() { printf '%s\n' "$*"; }
die() { printf 'pimipulse-agent installer: %s\n' "$*" >&2; exit 1; }
cleanup() { if [ -n "$WORK" ]; then rm -rf "$WORK"; fi; }

unit_file() {
cat <<'PIMIPULSE_UNIT'
[Unit]
Description=PimiPulse monitoring agent
Documentation=https://pimi.io/pulse/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pimipulse-agent run
Restart=always
RestartSec=10
Environment=PIMIPULSE_STATE_DIR=/var/lib/pimipulse

# Read-only agent: it reads /proc, /sys, /etc, /run/systemd/units and /lib/systemd,
# and writes only its state file in /var/lib/pimipulse (StateDirectory below).
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=/
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
PrivateTmp=yes
# With DynamicUser systemd keeps this at /var/lib/private/pimipulse behind a
# /var/lib/pimipulse symlink and chowns it (recursively) to the dynamic user on
# every start, so a root-owned agent.json written by `enroll` before the first
# start becomes the service's own.
StateDirectory=pimipulse
StateDirectoryMode=0750

[Install]
WantedBy=multi-user.target
PIMIPULSE_UNIT
}

usage() {
  cat <<'EOF'
usage: install.sh [--endpoint URL --code CODE [--re-enrol]] [--version X.Y.Z] [--dry-run]
       install.sh --uninstall

With --endpoint and --code the box is enrolled into a PimiPulse app and the agent started.
Without them the installed agent is upgraded in place (latest release unless --version is given).
EOF
  exit 2
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --endpoint) [ $# -ge 2 ] || die "--endpoint needs a URL."; ENDPOINT="$2"; shift 2 ;;
      --endpoint=*) ENDPOINT="${1#*=}"; shift ;;
      --code) [ $# -ge 2 ] || die "--code needs an enrolment code."; CODE="$2"; shift 2 ;;
      --code=*) CODE="${1#*=}"; shift ;;
      --version) [ $# -ge 2 ] || die "--version needs a version such as 0.2.0."; VERSION="$2"; shift 2 ;;
      --version=*) VERSION="${1#*=}"; shift ;;
      --re-enrol|--re-enroll) REENROL=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --uninstall) UNINSTALL=1; shift ;;
      -h|--help) usage ;;
      *) die "unknown option $1 (see --help)." ;;
    esac
  done
  if [ -n "$VERSION" ] && ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    die "--version must look like 0.2.0 (no v prefix)."
  fi
  if { [ -n "$ENDPOINT" ] && [ -z "$CODE" ]; } || { [ -z "$ENDPOINT" ] && [ -n "$CODE" ]; }; then
    die "--endpoint and --code go together."
  fi
  if [ -n "$ENDPOINT" ] && ! printf '%s' "$ENDPOINT" | grep -Eq '^https?://'; then
    die "--endpoint must be a URL starting with https:// (or http://)."
  fi
  if [ "$REENROL" -eq 1 ] && [ -z "$CODE" ]; then
    die "--re-enrol needs --endpoint and --code."
  fi
  if [ "$UNINSTALL" -eq 1 ] && { [ -n "$CODE" ] || [ -n "$VERSION" ]; }; then
    die "--uninstall takes no other options."
  fi
}

detect_arch() {
  [ "$(uname -s)" = "Linux" ] || die "the agent runs on Linux only."
  case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "unsupported CPU architecture $(uname -m); the agent is built for x86_64 and aarch64 only." ;;
  esac
}

enrolled() {
  [ -f "$STATE_DIR/agent.json" ] || [ -f /var/lib/private/pimipulse/agent.json ] || [ -f /etc/pimipulse/agent.json ]
}

installed_version() {
  if [ -x "$BIN" ]; then
    "$BIN" version </dev/null 2>/dev/null | awk '{print $2}' || true
  fi
}

fetch() { # url dest
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    die "curl or wget is required to download the agent."
  fi
}

download() {
  local asset base
  asset="pimipulse-agent-linux-$ARCH"
  if [ -n "$VERSION" ]; then
    base="$RELEASES/download/$VERSION"
  else
    base="$RELEASES/latest/download"
  fi
  WORK="$(mktemp -d)"
  say "Downloading $asset (${VERSION:-latest release})..."
  fetch "$base/SHA256SUMS" "$WORK/SHA256SUMS" || die "could not download $base/SHA256SUMS; check the version and the network."
  fetch "$base/$asset" "$WORK/$asset" || die "could not download $base/$asset."
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required to verify the download."
  (cd "$WORK" && grep -E "[[:space:]]\*?$asset\$" SHA256SUMS | sha256sum -c --status -) \
    || die "the checksum of $asset does not match SHA256SUMS; nothing was installed."
  chmod 0755 "$WORK/$asset"
  DOWNLOADED="$WORK/$asset"
  BIN_VERSION="$("$DOWNLOADED" version </dev/null 2>/dev/null | awk '{print $2}' || true)"
  [ -n "$BIN_VERSION" ] || die "the downloaded binary did not run on this box; nothing was installed."
  say "Verified pimipulse-agent $BIN_VERSION for $ARCH (checksum OK)."
}

print_plan() {
  say "Dry run: nothing was changed. A real run would"
  say "  - install the binary to $BIN"
  say "  - write the systemd unit to $UNIT"
  if [ -n "$CODE" ]; then
    say "  - enrol this box with $ENDPOINT into $STATE_DIR (before the first start)"
  else
    say "  - keep the existing enrolment in $STATE_DIR"
  fi
  say "  - systemctl daemon-reload, enable and restart pimipulse-agent, then run pimipulse-agent doctor"
}

do_uninstall() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "Dry run: a real run would stop and disable pimipulse-agent and remove $UNIT, $BIN, $STATE_DIR, /var/lib/private/pimipulse and /etc/pimipulse."
    return
  fi
  systemctl stop pimipulse-agent 2>/dev/null || true
  systemctl disable pimipulse-agent 2>/dev/null || true
  rm -f "$UNIT" "$DROPIN_DIR/group.conf"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload
  rm -f "$BIN"
  rm -rf /var/lib/private/pimipulse /etc/pimipulse
  rm -rf "$STATE_DIR"
  say "pimipulse-agent removed: service, binary and state. Remove the server in the PimiPulse app too if you no longer want it listed."
}

do_install() {
  local current
  current="$(installed_version)"
  install -m 0755 "$DOWNLOADED" "$BIN"
  unit_file > "$WORK/unit"
  install -m 0644 "$WORK/unit" "$UNIT"
  if [ -n "$CODE" ]; then
    # Enrol before the first start: a root-owned agent.json in a root-owned 0750 directory is handed to
    # the unit's dynamic user by systemd's StateDirectory on start. On a re-enrol the directory already
    # belongs to the dynamic user and the agent gives the new file to the directory's owner itself.
    "$BIN" enroll --endpoint "$ENDPOINT" --code "$CODE" --state-dir "$STATE_DIR" </dev/null \
      || die "enrolment failed (the app's answer is above); check the endpoint and the code and run again."
  fi
  # 0.1.0 installs kept state in /etc/pimipulse behind a group drop-in; no longer needed.
  rm -f "$DROPIN_DIR/group.conf"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable -q pimipulse-agent
  systemctl restart pimipulse-agent
  sleep 2
  systemctl --no-pager --lines=3 status pimipulse-agent </dev/null || true
  systemctl is-active --quiet pimipulse-agent \
    || die "the service did not stay up; see journalctl -u pimipulse-agent."
  if [ -n "$CODE" ]; then
    say "pimipulse-agent $BIN_VERSION enrolled and running."
  elif [ -n "$current" ] && [ "$current" != "$BIN_VERSION" ]; then
    say "pimipulse-agent upgraded $current -> $BIN_VERSION and running."
  else
    say "pimipulse-agent $BIN_VERSION reinstalled and running."
  fi
  "$BIN" doctor </dev/null || die "doctor reports a problem (above); the service is running and will keep retrying."
}

main() {
  trap cleanup EXIT
  parse_args "$@"
  detect_arch
  if [ "$UNINSTALL" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      [ "$(id -u)" -eq 0 ] || die "run as root (sudo)."
      command -v systemctl >/dev/null 2>&1 || die "systemd is required; nothing was changed."
    fi
    do_uninstall
    return
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    [ "$(id -u)" -eq 0 ] || die "run as root (sudo)."
    { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; } \
      || die "systemd is required; this installer only sets up a systemd service."
    if [ -n "$CODE" ] && [ "$REENROL" -eq 0 ] && enrolled; then
      die "this box is already enrolled; an upgrade needs no code (run without --endpoint and --code), or pass --re-enrol to enrol it again."
    fi
    if [ -z "$CODE" ] && ! enrolled; then
      die "this box is not enrolled yet; run again with --endpoint URL --code pp_enr_... from the PimiPulse app."
    fi
  fi
  download
  if [ "$DRY_RUN" -eq 1 ]; then
    print_plan
    return
  fi
  do_install
}

main "$@"

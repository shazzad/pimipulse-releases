#!/usr/bin/env bash
# PimiPulse agent installer: enrol, upgrade or remove the agent on a Linux box with systemd.
#
# Needs Ubuntu 22.04+ or Debian 12+ (systemd, OpenSSL 3.0 for the signature check).
#
#   Enrol:    curl -fsSL https://raw.githubusercontent.com/shazzad/pimipulse-releases/main/install.sh \
#               | sudo bash -s -- --endpoint https://pulse.example.com --code pp_enr_...
#   Upgrade:  curl -fsSL https://raw.githubusercontent.com/shazzad/pimipulse-releases/main/install.sh | sudo bash
#   Remove:   curl -fsSL https://raw.githubusercontent.com/shazzad/pimipulse-releases/main/install.sh | sudo bash -s -- --uninstall
#
# Options:
#   --version X.Y.Z   install that release instead of the latest one (0.4.0 or later; may be older
#                     than the installed one, which a plain upgrade refuses)
#   --re-enrol        enrol again on a box that is already enrolled (needs --endpoint and --code)
#   --dry-run         download and verify only, then print what a real run would do (no root needed)
#
# It installs two binaries: /usr/local/bin/pimipulse-agent (the unprivileged monitor) and
# /usr/local/bin/pimipulse-update (the root helper that installs agent releases the agent staged; it
# is never auto-updated, only a new run of this installer replaces it), plus four systemd units.
#
# Nothing downloaded runs before it is verified, and the agent never runs as root here: the
# release signature (Ed25519 over the version and SHA256SUMS, key pinned below) is checked with
# openssl first, then each binary's checksum; the version comes from the signature line, not from
# running a binary; enrolment runs the agent under a one-off uid nothing else uses. The one root step that runs downloaded code
# is `pimipulse-update record-install`, after verification: that binary is the root helper systemd
# will run as root anyway.
#
# The source of this file is deploy/install.sh in shazzad/pimipulse-agent; bin/release copies it to
# the public releases repo. The systemd units below are copies of deploy/*.service, *.path and
# *.timer so the one-liner needs no second file; bin/release refuses to release if any differ, or if
# RELEASE_PUBKEY differs from internal/release/keys.go.
set -euo pipefail

RELEASES="https://github.com/shazzad/pimipulse-releases/releases"
# Raw Ed25519 public key (base64) that signs releases; key id 387e5f321c24fb44.
RELEASE_PUBKEY="JAUKVhVK9vNNfl3jdlF2DmJmNezSDIHKFYB7LC3/N/Q="
BIN=/usr/local/bin/pimipulse-agent
HELPER=/usr/local/bin/pimipulse-update
UNIT=/etc/systemd/system/pimipulse-agent.service
UPD_SERVICE=/etc/systemd/system/pimipulse-agent-update.service
UPD_PATH=/etc/systemd/system/pimipulse-agent-update.path
UPD_TIMER=/etc/systemd/system/pimipulse-agent-update.timer
DROPIN_DIR=/etc/systemd/system/pimipulse-agent.service.d
STATE_DIR=/var/lib/pimipulse
UPDATE_DIR=/var/lib/pimipulse-update
MIN_VERSION=0.4.0
NOBODY=65534

ENDPOINT=""
CODE=""
VERSION=""
REENROL=0
DRY_RUN=0
UNINSTALL=0
ARCH=""
WORK=""
DOWNLOADED=""
DOWNLOADED_HELPER=""
BIN_VERSION=""
CURRENT=""

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
# The agent needs about 15 MB (a release download, capped at 24 MB, is held in
# memory); a hard cap so nothing the app sends can make it eat the box.
MemoryMax=64M
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

update_service_file() {
cat <<'PIMIPULSE_UPDATE_SERVICE'
[Unit]
Description=PimiPulse agent updater (installs a release the agent staged)
Documentation=https://pimi.io/pulse/
# The only PimiPulse code that runs as root after install: /usr/local/bin/pimipulse-update,
# stdlib only, no network. It re-verifies the staged release with its own pinned key,
# installs it, restarts pimipulse-agent and rolls back if the new version does not report.

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pimipulse-update apply
# Two health watches of up to 6 minutes each (new version, then the rollback).
TimeoutStartSec=20min
PrivateNetwork=yes
ProtectSystem=strict
ReadWritePaths=/usr/local/bin -/var/lib/pimipulse-update -/var/lib/private/pimipulse
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
PIMIPULSE_UPDATE_SERVICE
}

update_path_file() {
cat <<'PIMIPULSE_UPDATE_PATH'
[Unit]
Description=PimiPulse: install an agent release when the agent stages one
Documentation=https://pimi.io/pulse/

[Path]
# The agent's StateDirectory with DynamicUser=yes; it writes "ready" last.
PathExists=/var/lib/private/pimipulse/staged/ready
Unit=pimipulse-agent-update.service
# The helper always moves the staged set aside, so this should fire once per
# staging; if something keeps it firing, stop after 5 in 10 minutes (the timer
# still runs the helper hourly).
TriggerLimitIntervalSec=10min
TriggerLimitBurst=5

[Install]
WantedBy=multi-user.target
PIMIPULSE_UPDATE_PATH
}

update_timer_file() {
cat <<'PIMIPULSE_UPDATE_TIMER'
[Unit]
Description=PimiPulse: run the agent updater at boot and hourly
Documentation=https://pimi.io/pulse/

[Timer]
# After boot (2 minutes after systemd starts; OnBootSec would count from the
# kernel's boot, which in a container can be long past): finish an install a
# reboot interrupted (state.json "pending"), so a crashing new version is rolled back.
OnStartupSec=2min
# Hourly safety net: a staged release the path unit missed, or a helper that was
# killed mid-check. With nothing pending or staged it exits at once.
OnCalendar=hourly
RandomizedDelaySec=5min
Persistent=true
Unit=pimipulse-agent-update.service

[Install]
WantedBy=timers.target
PIMIPULSE_UPDATE_TIMER
}

usage() {
  cat <<'USAGE'
usage: install.sh [--endpoint URL --code CODE [--re-enrol]] [--version X.Y.Z] [--dry-run]
       install.sh --uninstall

With --endpoint and --code the box is enrolled into a PimiPulse app and the agent started.
Without them the installed agent is upgraded in place (latest release unless --version is given).
USAGE
  exit 2
}

is_version() { printf '%s' "${1:-}" | grep -Eq '^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'; }

# version_ge A B: A >= B for X.Y.Z versions.
version_ge() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
  [ "$a3" -ge "$b3" ]
}

# Run a command as nobody, no supplementary groups, no privilege gain.
as_nobody() { setpriv --reuid="$NOBODY" --regid="$NOBODY" --clear-groups --no-new-privs -- "$@"; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --endpoint) [ $# -ge 2 ] || die "--endpoint needs a URL."; ENDPOINT="$2"; shift 2 ;;
      --endpoint=*) ENDPOINT="${1#*=}"; shift ;;
      --code) [ $# -ge 2 ] || die "--code needs an enrolment code."; CODE="$2"; shift 2 ;;
      --code=*) CODE="${1#*=}"; shift ;;
      --version) [ $# -ge 2 ] || die "--version needs a version such as 0.4.0."; VERSION="$2"; shift 2 ;;
      --version=*) VERSION="${1#*=}"; shift ;;
      --re-enrol|--re-enroll) REENROL=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --uninstall) UNINSTALL=1; shift ;;
      -h|--help) usage ;;
      *) die "unknown option $1 (see --help)." ;;
    esac
  done
  if [ -n "$VERSION" ] && ! is_version "$VERSION"; then
    die "--version must look like 0.4.0 (no v prefix)."
  fi
  if [ -n "$VERSION" ] && ! version_ge "$VERSION" "$MIN_VERSION"; then
    die "this installer sets up $MIN_VERSION or later (signed releases with the update helper); $VERSION is older."
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

# The installed version, without running anything as root: the helper's root-owned record,
# else the installed binary run as nobody (boxes from before 0.4.0). Empty when unknown.
installed_version() {
  local v=""
  if [ -f "$UPDATE_DIR/state.json" ] && [ ! -L "$UPDATE_DIR/state.json" ]; then
    v="$(sed -n 's/^ *"installed_version": *"\([0-9.]*\)".*/\1/p' "$UPDATE_DIR/state.json" 2>/dev/null | head -n 1 || true)"
  fi
  if ! is_version "$v" && [ -x "$BIN" ] && [ "$(id -u)" -eq 0 ] && command -v setpriv >/dev/null 2>&1; then
    v="$(as_nobody "$BIN" version </dev/null 2>/dev/null | awk '{print $2}' || true)"
  fi
  if is_version "$v"; then printf '%s' "$v"; fi
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

# verify_signature DIR: check DIR/SHA256SUMS.sig over DIR/SHA256SUMS with the pinned key, using
# openssl only (nothing downloaded is executed). Sets BIN_VERSION from the signed line.
verify_signature() {
  local dir="$1" prefix="" keyid="" version="" sig="" extra="" want_id
  command -v openssl >/dev/null 2>&1 || die "openssl is required to check the release signature (apt-get install openssl)."
  # Ed25519 over raw data needs pkeyutl -rawin, added in OpenSSL 3.0.
  openssl pkeyutl -help 2>&1 | grep -q -- '-rawin' \
    || die "checking the release signature needs OpenSSL 3.0 or later (Ubuntu 22.04+, Debian 12+); this box has $(openssl version 2>/dev/null || echo an older one)."
  [ "$(wc -c <"$dir/SHA256SUMS.sig")" -le 1024 ] || die "SHA256SUMS.sig is too large; nothing was installed."
  [ "$(wc -c <"$dir/SHA256SUMS")" -le 16384 ] || die "SHA256SUMS is too large; nothing was installed."
  read -r prefix keyid version sig extra <"$dir/SHA256SUMS.sig" || true
  { [ "$prefix" = "pimipulse-sig-v1" ] && [ -n "$sig" ] && [ -z "$extra" ]; } \
    || die "SHA256SUMS.sig is not a PimiPulse release signature (releases before $MIN_VERSION are not signed)."
  is_version "$version" || die "SHA256SUMS.sig names no valid version."
  if [ -n "$VERSION" ] && [ "$version" != "$VERSION" ]; then
    die "the signature is for $version, not the requested $VERSION; nothing was installed."
  fi
  want_id="$(printf '%s' "$RELEASE_PUBKEY" | base64 -d | sha256sum | cut -c1-16)"
  [ "$keyid" = "$want_id" ] || die "the release is signed with key $keyid, not PimiPulse's key $want_id; nothing was installed."
  # SubjectPublicKeyInfo DER for Ed25519 = fixed 12-byte prefix + the 32-byte key.
  { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf '%s' "$RELEASE_PUBKEY" | base64 -d; } >"$dir/pub.der"
  printf '%s' "$sig" | base64 -d >"$dir/sig.bin" 2>/dev/null || die "SHA256SUMS.sig holds no valid signature."
  { printf 'pimipulse-agent release v1\nversion %s\n' "$version"; cat "$dir/SHA256SUMS"; } >"$dir/msg"
  openssl pkeyutl -verify -pubin -keyform DER -inkey "$dir/pub.der" -rawin -in "$dir/msg" -sigfile "$dir/sig.bin" >/dev/null 2>&1 \
    || die "the release signature does not verify; nothing was installed."
  BIN_VERSION="$version"
}

download() {
  local asset helper_asset base f
  asset="pimipulse-agent-linux-$ARCH"
  helper_asset="pimipulse-update-linux-$ARCH"
  if [ -n "$VERSION" ]; then
    base="$RELEASES/download/$VERSION"
  else
    base="$RELEASES/latest/download"
  fi
  WORK="$(mktemp -d)"
  say "Downloading the release signature (${VERSION:-latest release})..."
  fetch "$base/SHA256SUMS" "$WORK/SHA256SUMS" || die "could not download $base/SHA256SUMS; check the version and the network."
  fetch "$base/SHA256SUMS.sig" "$WORK/SHA256SUMS.sig" || die "could not download $base/SHA256SUMS.sig (releases before $MIN_VERSION are not signed; use $MIN_VERSION or later)."
  verify_signature "$WORK"
  version_ge "$BIN_VERSION" "$MIN_VERSION" || die "the release is $BIN_VERSION; this installer needs $MIN_VERSION or later."
  CURRENT="$(installed_version)"
  if [ -z "$VERSION" ] && [ -n "$CURRENT" ] && ! version_ge "$BIN_VERSION" "$CURRENT"; then
    die "the latest release is $BIN_VERSION but $CURRENT is installed; nothing was changed (pass --version $BIN_VERSION to go back on purpose)."
  fi
  # The binaries come from the signed version's own URL, so "latest" cannot move in between.
  base="$RELEASES/download/$BIN_VERSION"
  say "Signature OK for $BIN_VERSION. Downloading $asset and $helper_asset..."
  fetch "$base/$asset" "$WORK/$asset" || die "could not download $base/$asset."
  fetch "$base/$helper_asset" "$WORK/$helper_asset" || die "could not download $base/$helper_asset."
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required to verify the download."
  for f in "$asset" "$helper_asset"; do
    [ "$(grep -cE "^[0-9a-f]{64}[[:space:]]+\*?$f\$" "$WORK/SHA256SUMS")" = 1 ] \
      || die "SHA256SUMS has no single line for $f; nothing was installed."
    (cd "$WORK" && grep -E "^[0-9a-f]{64}[[:space:]]+\*?$f\$" SHA256SUMS | sha256sum -c --status -) \
      || die "the checksum of $f does not match the signed SHA256SUMS; nothing was installed."
  done
  chmod 0755 "$WORK/$asset" "$WORK/$helper_asset"
  DOWNLOADED="$WORK/$asset"
  DOWNLOADED_HELPER="$WORK/$helper_asset"
  say "Verified pimipulse-agent $BIN_VERSION for $ARCH (signature and checksums OK)."
}

print_plan() {
  say "Dry run: nothing was changed. A real run would"
  say "  - install the agent to $BIN and the update helper to $HELPER (both root-owned 0755)"
  say "  - write the systemd units $UNIT, $UPD_SERVICE, $UPD_PATH and $UPD_TIMER"
  say "  - create $UPDATE_DIR (root, 0755) and record $BIN_VERSION as installed there"
  if [ -n "$CODE" ]; then
    say "  - enrol this box with $ENDPOINT (the agent runs under a one-off unused uid for it), state in $STATE_DIR"
  else
    say "  - keep the existing enrolment in $STATE_DIR"
  fi
  say "  - systemctl daemon-reload, enable and restart pimipulse-agent, enable pimipulse-agent-update.path and .timer, then wait for the agent's first report"
}

do_uninstall() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "Dry run: a real run would stop and disable pimipulse-agent and its update units and remove $UNIT, $UPD_SERVICE, $UPD_PATH, $UPD_TIMER, $DROPIN_DIR, $BIN, $HELPER, $UPDATE_DIR, $STATE_DIR, /var/lib/private/pimipulse and /etc/pimipulse."
    return
  fi
  systemctl stop pimipulse-agent-update.path pimipulse-agent-update.timer 2>/dev/null || true
  systemctl disable pimipulse-agent-update.path pimipulse-agent-update.timer 2>/dev/null || true
  systemctl stop pimipulse-agent-update.service 2>/dev/null || true
  systemctl stop pimipulse-agent 2>/dev/null || true
  systemctl disable pimipulse-agent 2>/dev/null || true
  rm -f "$UNIT" "$UPD_SERVICE" "$UPD_PATH" "$UPD_TIMER"
  rm -rf "$DROPIN_DIR"
  systemctl daemon-reload
  rm -f "$BIN" "$HELPER"
  rm -rf "$UPDATE_DIR" /var/lib/private/pimipulse /etc/pimipulse
  rm -rf "$STATE_DIR"
  say "pimipulse-agent removed: services, update units, both binaries and state. Remove the server in the PimiPulse app too if you no longer want it listed."
}

# Enrol under a one-off identity: a random uid above 4,000,000,000 that no account and no running
# process has (checked), so no other process shares it (nobody is shared: another nobody process
# could read the new key or swap the file). The agent generates the key and talks to the app in a
# 0700 directory owned by that uid; the file is then read back AS that uid into a temp file root
# opened in $UPDATE_DIR (a symlink planted there could expose nothing that uid cannot read), and
# renamed into the state directory, so nothing is written through a name the agent's user could
# have turned into a symlink. (systemd-run with DynamicUser=yes would do the same but needs D-Bus,
# which minimal images lack.)
as_uid() { local u="$1"; shift; setpriv --reuid="$u" --regid="$u" --clear-groups --no-new-privs -- "$@"; }
enrol() {
  local tmp owner uid dir
  command -v setpriv >/dev/null 2>&1 || die "setpriv (util-linux) is required to enrol without running the agent as root."
  uid=$(( 4000000000 + (RANDOM * 32768 + RANDOM) % 290000000 )) # below 4294967295 (-1)
  if getent passwd "$uid" >/dev/null 2>&1 || ps -e -o uid= | grep -qw "$uid"; then
    die "uid $uid is in use; run the installer again."
  fi
  chmod 0711 "$WORK"
  dir="$WORK/enrol-$RANDOM$RANDOM"
  install -d -m 0700 -o "$uid" -g "$uid" "$dir"
  as_uid "$uid" "$BIN" enroll --endpoint "$ENDPOINT" --code "$CODE" --state-dir "$dir" </dev/null \
    || die "enrolment failed (the app's answer is above); check the endpoint and the code and run again."
  tmp="$UPDATE_DIR/.agent.json.new"
  rm -f "$tmp"
  (umask 077 && as_uid "$uid" head -c 65536 "$dir/agent.json" >"$tmp") || die "could not read the new enrolment."
  [ -s "$tmp" ] || die "enrolment wrote no agent.json."
  rm -rf "$dir"
  chmod 0640 "$tmp"
  if [ -d "$STATE_DIR" ]; then
    owner="$(stat -L -c '%u:%g' "$STATE_DIR")"
  else
    install -d -m 0750 -o root -g root "$STATE_DIR"
    owner="0:0"
  fi
  chown "$owner" "$tmp"
  mv -fT "$tmp" "$STATE_DIR/agent.json"
  say "Enrolment saved to $STATE_DIR/agent.json."
}

# Wait for status.json to show a successful post after $1 (unix seconds). Read as data only.
wait_for_report() {
  local f="$STATE_DIR/status.json" ok="" _
  for _ in $(seq 1 50); do
    if [ -f "$f" ] && [ ! -L "$f" ]; then
      ok="$(sed -n 's/.*"last_ok_at":\([0-9]\{1,12\}\).*/\1/p' "$f" 2>/dev/null | head -n 1 || true)"
      if [ -n "$ok" ] && [ "$ok" -ge "$1" ]; then
        say "The agent reported to the app (status.json last_ok_at $ok)."
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

do_install() {
  local started
  # An auto-update in progress must not race the installer; the units come back below.
  systemctl stop pimipulse-agent-update.path pimipulse-agent-update.timer pimipulse-agent-update.service 2>/dev/null || true
  install -m 0755 -o root -g root "$DOWNLOADED" "$BIN"
  install -m 0755 -o root -g root "$DOWNLOADED_HELPER" "$HELPER"
  unit_file >"$WORK/unit"
  install -m 0644 "$WORK/unit" "$UNIT"
  update_service_file >"$WORK/upd.service"
  install -m 0644 "$WORK/upd.service" "$UPD_SERVICE"
  update_path_file >"$WORK/upd.path"
  install -m 0644 "$WORK/upd.path" "$UPD_PATH"
  update_timer_file >"$WORK/upd.timer"
  install -m 0644 "$WORK/upd.timer" "$UPD_TIMER"
  install -d -m 0755 -o root -g root "$UPDATE_DIR"
  if [ -n "$CODE" ]; then
    enrol
  fi
  # Verified above; this is the root helper systemd runs as root anyway.
  "$HELPER" record-install "$BIN_VERSION" </dev/null || die "could not record the installed version in $UPDATE_DIR."
  # 0.1.0 installs kept state in /etc/pimipulse behind a group drop-in; no longer needed.
  rm -f "$DROPIN_DIR/group.conf"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable -q pimipulse-agent
  started="$(date +%s)"
  systemctl restart pimipulse-agent
  systemctl enable -q --now pimipulse-agent-update.path pimipulse-agent-update.timer
  sleep 2
  systemctl --no-pager --lines=3 status pimipulse-agent </dev/null || true
  systemctl is-active --quiet pimipulse-agent \
    || die "the service did not stay up; see journalctl -u pimipulse-agent."
  if [ -n "$CODE" ]; then
    say "pimipulse-agent $BIN_VERSION enrolled and running."
  elif [ -n "$CURRENT" ] && [ "$CURRENT" != "$BIN_VERSION" ]; then
    say "pimipulse-agent upgraded $CURRENT -> $BIN_VERSION and running."
  else
    say "pimipulse-agent $BIN_VERSION reinstalled and running."
  fi
  say "Installed: $BIN, $HELPER, $UNIT, $UPD_SERVICE, $UPD_PATH, $UPD_TIMER, $UPDATE_DIR; state in $STATE_DIR."
  say "Auto-update is on: the agent fetches signed releases itself and $HELPER installs them (it is updated only by this installer)."
  if [ -n "$CODE" ]; then
    say "Waiting for the agent's first report (a few seconds)..."
  else
    say "Waiting for the agent's first report (up to a minute)..."
  fi
  wait_for_report "$started" \
    || die "the agent is running but has not reported yet; see journalctl -u pimipulse-agent, or run: sudo $BIN doctor"
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

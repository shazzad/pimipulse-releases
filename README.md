# PimiPulse agent releases

[PimiPulse](https://pimi.io/pulse/) is server monitoring for people who run their own VM and want
a plain-English answer to "is this server fine, and when should I upgrade it?". This repo holds the
release builds of the small agent that runs on your server, plus the installer; the agent and app
source live elsewhere.

## Install

On the server, as root, with the endpoint and the enrolment code the PimiPulse app shows you:

```
curl -fsSL https://raw.githubusercontent.com/shazzad/pimipulse-releases/main/install.sh | sudo bash -s -- --endpoint https://pulse.example.com --code pp_enr_...
```

Upgrade to the latest release (the server stays enrolled, no code needed):

```
curl -fsSL https://raw.githubusercontent.com/shazzad/pimipulse-releases/main/install.sh | sudo bash
```

Remove the agent, its service and its state:

```
curl -fsSL https://raw.githubusercontent.com/shazzad/pimipulse-releases/main/install.sh | sudo bash -s -- --uninstall
```

`--version 0.2.0` installs a specific release; `--re-enrol` enrols an already-enrolled server
again; `--dry-run` only downloads and verifies and prints what a real run would do. Linux with
systemd on x86_64 or aarch64 (arm64); `curl` and `sha256sum` are the only tools needed.

## If something looks wrong

These are the only commands we will ever ask you to run:

```
systemctl status pimipulse-agent
journalctl -u pimipulse-agent
sudo systemctl restart pimipulse-agent
```

`sudo pimipulse-agent doctor` prints whether the server is enrolled and can reach the app.

## What the agent does

It reads `/proc`, `/sys`, the systemd unit list under `/run/systemd/units` and a few files in
`/etc` and `/lib/systemd` every 10 seconds, reduces that to one record a minute (CPU, load, memory,
swap, pressure, disk, network, the top processes, and whether nginx, PHP-FPM, MySQL/MariaDB, Redis
and similar services are running), and posts it to your PimiPulse app, signed with a key that never
leaves the server.

It is read-only. The service runs as a dynamic unprivileged user with the whole filesystem mounted
read-only; the only thing it writes is its own state file in `/var/lib/pimipulse`. It never runs
commands for the app, never opens a port, and has no SSH key or shell access to anything.

## Checksums

Every release carries `SHA256SUMS`, and the installer refuses to install a binary whose checksum
does not match. The binaries are not code-signed yet; the checksums are the integrity check for now.

## License

Apache-2.0, see `LICENSE`.

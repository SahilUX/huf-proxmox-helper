# HUF Proxmox LXC Helper

Creates a dedicated, native Ubuntu LXC for a clean [HUF](https://github.com/tridz-dev/huf) installation on Proxmox VE.

> This is an independent helper inspired by the structure and conventions of [Proxmox VE Helper-Scripts](https://community-scripts.github.io/ProxmoxVE/). It is not an official Community Scripts entry.

## Quick start

Run on a Proxmox VE host as `root`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/SahilUX/huf-proxmox-helper/main/install-huf-lxc.sh)"
```

The installer defaults to:

- CT ID: `100`
- Hostname: `huf`
- Tags: `ai;automation`
- CPU: 4 cores
- Memory: 4096 MiB
- Swap: 1024 MiB
- Disk: 30 GiB
- Network: DHCP on `vmbr0`
- Storage: `local-lvm`, with LXC template from `local`
- Frappe major: `15`

All defaults are shown as prompts and can be changed during installation.

## What it installs

- unprivileged Ubuntu 24.04 LXC with `nesting=1` and `keyctl=1`
- native MariaDB, Redis, Supervisor, and Nginx
- Node.js, Yarn, `uv`, Bench, and a fresh Frappe site
- the HUF application from `tridz-dev/huf` branch `develop`
- a single-site Nginx configuration for direct LAN IP access, without adding a client-side `IP huf.local` hosts entry

## Frappe version policy

The interactive installer offers Frappe 14, 15, and 16.

- **15** is the default and recommended HUF target.
- **14** is retained as a legacy option.
- **16** is blocked by default. As of 2026-08-13, HUF's current LiteLLM constraint is not compatible with Frappe 16's Python 3.14 runtime. You may only bypass this guard deliberately:

```bash
HUF_ALLOW_UNSUPPORTED_V16=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/SahilUX/huf-proxmox-helper/main/install-huf-lxc.sh)"
```

An override is not a claim that HUF v16 will install successfully.

## Credentials

The installer generates random Frappe Administrator and MariaDB root passwords. It intentionally does not print them into the Proxmox-host log.

After the install completes, print the local LXC credentials only when needed:

```bash
pct exec <CTID> -- cat /root/huf.credentials
```

## Development and validation

```bash
bash -n install-huf-lxc.sh
```

A full validation requires a disposable Proxmox CT and verifies both HTTP availability and that `huf` appears in `bench --site huf.local list-apps`.

## Security notes

- HUF includes execution and integration features. Treat it as a privileged internal service.
- No Tailnet, Funnel, or public exposure is configured by this script.
- Configure authenticated HTTPS and any remote access separately after validating the local deployment.

## License

MIT. See [LICENSE](LICENSE).

# HUF Proxmox LXC Helper

A full-screen Proxmox VE Helper-Scripts style installer for a clean, native [HUF](https://github.com/tridz-dev/huf) installation.

> This is an independent helper that uses the Community Scripts full-screen LXC builder UI and its tested container lifecycle functions. It is not an official Community Scripts entry.

## Quick start

Run on a Proxmox VE host as `root`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/SahilUX/huf-proxmox-helper/main/huf.sh)"
```

This opens the same full-screen interactive install flow used by Community Scripts, including **Default Install**, **Advanced Install**, storage selection, resource settings, network settings, and safety checks.

## Prescribed defaults

| Setting | Default |
|---|---:|
| CT ID | Next available, editable in Advanced Install |
| Hostname | `huf` |
| Tags | `ai;automation` |
| CPU | 4 cores |
| Memory | 4096 MiB |
| Disk | 30 GiB |
| OS | Ubuntu 24.04 |
| Network | DHCP on `vmbr0` |
| Root filesystem storage | Proxmox UI default |
| Frappe major | 15 |
| Node.js | 20 for Frappe 14/15; 24 for Frappe 16 |

The Community Scripts UI chooses the next available CT ID for Default Install, and exposes CT ID as an editable field in Advanced Install. Resources, storage, and networking remain customizable through the normal full-screen flow.

## What it installs

- an unprivileged Ubuntu 24.04 LXC with `nesting=1` and `keyctl=1`
- native MariaDB, Redis, Supervisor, and Nginx
- Node.js, Yarn, `uv`, Bench, and a fresh Frappe site
- HUF from `tridz-dev/huf` branch `develop`
- a single-site Nginx configuration for direct LAN IP access without adding a client-side `IP huf.local` hosts entry

## Frappe version policy

The full-screen launcher offers Frappe 14, 15, and 16.

- **15** is the supported default for HUF.
- **14** is retained as a legacy option.
- **16** is blocked by default. HUF's current LiteLLM constraint is incompatible with Frappe 16's Python 3.14 runtime. You can bypass that guard only after upstream compatibility is confirmed:

```bash
HUF_ALLOW_UNSUPPORTED_V16=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/SahilUX/huf-proxmox-helper/main/huf.sh)"
```

An override does not imply that HUF v16 will install successfully.

## Credentials

The installer generates random Frappe Administrator and MariaDB root passwords. It does not print them into installer logs.

After a successful installation, retrieve them locally from the Proxmox host:

```bash
pct exec <CT_ID> -- cat /root/huf.credentials
```

## Files

- `huf.sh`: Proxmox-host launcher. Presents the full-screen interactive UI.
- `install-huf-lxc.sh`: container-side HUF installation payload.

## Validation

```bash
bash -n huf.sh install-huf-lxc.sh
```

A full validation requires a disposable Proxmox CT and checks both HTTP availability and that `huf` appears in `bench --site huf.local list-apps`.

## Security notes

- HUF includes execution and integration features. Treat it as a privileged internal service.
- This script does not configure Tailscale, Funnel, or public exposure.
- Configure authenticated HTTPS and any remote access separately after validating LAN access.

## License

MIT. See [LICENSE](LICENSE).

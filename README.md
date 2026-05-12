[English](README.md) | [한국어](README.ko.md)

# pbs-bootstrap

Disaster-recover a [Proxmox Backup Server](https://www.proxmox.com/en/proxmox-backup-server) (PBS) LXC from a Backblaze B2 cold mirror — in one command, on a fresh Proxmox VE bare-metal install.

> ⚠️ One-shot DR tool. It does **not** keep PBS in sync with B2 day-to-day; that's your steady-state IaC's job (cron, ansible, etc).

## Table of contents

- [Use case](#use-case)
- [What bootstrap.sh actually does](#what-bootstrapsh-actually-does)
- [Requirements](#requirements)
- [First-time setup](#first-time-setup) (before any DR can work)
- [DR usage (the actual recovery)](#dr-usage-the-actual-recovery)
- [Configuration — env vars](#configuration--env-vars)
- [Network shim](#network-shim)
- [Troubleshooting](#troubleshooting)
- [After bootstrap (operator handoff)](#after-bootstrap-operator-handoff)
- [License](#license)

## Use case

You run PBS in an LXC on Proxmox VE, and you rclone the PBS datastore to B2 on a schedule. One day your Proxmox host is gone — disk failure, ransomware, lab accident, whatever. What you still have:

- a B2 chunks bucket (the datastore byte-for-byte)
- a B2 meta bucket (config + ssh keys, populated by steady-state automation)
- the 4 B2 application key values, kept somewhere outside the homelab

`bootstrap.sh` takes you from a **fresh PVE bare-metal install** all the way to a **working PVE → PBS chain** — you can immediately browse and restore your backups from the PVE GUI. What you do with those backups afterwards is your operator playbook, deliberately out of scope here.

When **not** to use this:

- Your PBS LXC is fine and you're just rotating the host or upgrading PBS. Use your normal terraform / ansible.
- You don't have a B2 cold mirror. There's nothing to restore from.
- You want PBS → B2 sync on a schedule. That's steady-state, not bootstrap.

## What bootstrap.sh actually does

1. Fixes the Proxmox host's apt repos (`pve-enterprise` → `pve-no-subscription`) and installs deps (`rclone`, `yq`, `iptables`, `ifupdown2`).
2. Configures rclone B2 remotes on the host and pulls `bootstrap-config.yml` from the meta bucket.
3. Materializes the host's additional bridges (`host.bridges[*]` from config — typically `vmbr1`) into `/etc/network/interfaces.d/` and reloads networking.
4. Fetches the operator's `authorized_keys` from B2 meta, installs it on the host, and stages it for LXC injection.
5. Enables host-side `iptables` MASQUERADE so the new LXC has internet even when the LAN firewall is down.
6. Creates an unprivileged Debian 12 LXC sized to `pbs.rootfs_*` and `pbs.cores` / `pbs.memory_*` from config.
7. Installs `proxmox-backup-server` inside the LXC (no-subscription repo, modern keyring path).
8. Restores chunks from the B2 chunks bucket via `rclone copy` (foreground, with progress), `chown`ed to `backup:backup`.
9. Registers the datastore with PBS (writes `/etc/proxmox-backup/datastore.cfg`, reloads the proxy).
10. Creates a PBS API user + token + `DatastoreAdmin` ACL.
11. Adds a PBS storage entry to PVE (`/etc/pve/storage.cfg`) using the new token + the PBS TLS fingerprint.
12. Restores the LXC's network to the declared steady-state gateway and tears down the host masquerade.

**Success criteria**: in PVE GUI you see the `pbs` storage with backups browsable.

## Requirements

To run bootstrap.sh you need:

- **Proxmox VE host** — fresh bare-metal install. The installer's network ceremony provides `vmbr0` with internet via your upstream router.
- **Browser access to the PVE GUI** (`https://<vmbr0-ip>:8006`). SSH from your laptop isn't required during DR — bootstrap plants the operator key from the B2 mirror as it runs.
- **B2 credentials** — 4 values stored outside the homelab:
  - `B2_PBS_META_KEY_ID` / `B2_PBS_META_KEY` — read on the meta bucket
  - `B2_PBS_KEY_ID` / `B2_PBS_KEY` — read on the chunks bucket
- **B2 bucket contents** prepared in advance (see [First-time setup](#first-time-setup)):
  - `bootstrap-config.yml` in the meta bucket
  - `authorized_keys` in the meta bucket (optional; falls back to `PBS_SSH_PUBKEY_FILE`)
- **Host upstream independent of the LAN firewall VM you're recovering**. The host's default route must point at your consumer router / ISP modem, not at the dead pfSense / OPNsense / etc. Verify with `curl -I https://api.backblazeb2.com` on the host before running bootstrap.

## First-time setup

Do this once, before any disaster. After that your steady-state automation keeps the meta bucket current.

### 1. Create two B2 buckets

In the Backblaze B2 console:

- **Chunks bucket** (e.g. `my-pbs-chunks`) — large, holds the PBS datastore byte-for-byte.
- **Meta bucket** (e.g. `my-pbs-meta`) — tiny, holds `bootstrap-config.yml` + `authorized_keys`.

Bucket type: Private. Lifecycle / encryption / region: your policy.

### 2. Issue narrow-scope application keys

Two key pairs, each scoped to one bucket. From B2 console → **Application Keys** → **Add a New Application Key**:

| Key role | Bucket scope | Bootstrap permissions | Steady-state permissions (additional) |
|---|---|---|---|
| `PBS_KEY` | chunks bucket only | `listBuckets`, `listFiles`, `readFiles` | `writeFiles`, `deleteFiles` (for nightly rclone sync) |
| `PBS_META_KEY` | meta bucket only | `listBuckets`, `listFiles`, `readFiles` | `writeFiles` (for ansible to refresh `bootstrap-config.yml` / `authorized_keys`) |

**Store the 4 key values outside your homelab** — password manager, encrypted USB, paper backup. In a real DR your Infisical / Vaultwarden / homelab vault is also gone; these 4 values must be retrievable from outside.

### 3. Craft `bootstrap-config.yml`

The format `bootstrap.sh` reads:

```yaml
pbs:
  vmid:             200
  hostname:         pbs
  bridge:           vmbr1
  ip:               10.80.60.200
  gateway:          10.80.60.1
  datastore_name:   system-backup
  datastore_path:   /mnt/pbs_backup
  rootfs_size:      100              # GB
  rootfs_storage:   local            # PVE storage ID
  cores:            2
  memory_dedicated: 2048             # MB
  memory_swap:      1024             # MB

# Bridges the host needs *in addition to* vmbr0 (the PVE installer creates vmbr0).
# Each becomes a drop-in at /etc/network/interfaces.d/<name>.conf.
# Empty list → bootstrap skips this step.
host:
  bridges:
    - name:         vmbr1
      address:      10.80.60.254/24
      bridge_ports: none
      static_routes:
        - { subnet: 10.80.80.0/24, gateway: 10.80.60.1 }

b2:
  chunks_bucket: my-pbs-chunks
  meta_bucket:   my-pbs-meta
```

Field semantics:

- `pbs.*` — terraform-shaped attributes of the PBS LXC. After bootstrap the running LXC matches these.
- `host.bridges[*]` — additional host bridges. `vmbr0` is intentionally NOT here (the PVE installer owns it).
- `b2.*` — bucket names; used as remote names in rclone config.

In our homelab this file is rendered by an ansible role on every apply, so `bootstrap.sh` always pulls the latest state.

### 4. Upload to the meta bucket

```bash
# Install rclone locally if you don't have it
brew install rclone   # macOS
# or: apt install -y rclone

# Configure a B2 remote with your META key
rclone config create meta b2 \
  account=<META_KEY_ID> \
  key=<META_APP_KEY>

# Upload the config
rclone copyto bootstrap-config.yml meta:my-pbs-meta/bootstrap-config.yml

# (Optional) seed authorized_keys — one SSH public key per line
cat ~/.ssh/operator.pub | rclone rcat meta:my-pbs-meta/authorized_keys
```

If you skip the optional `authorized_keys` upload, bootstrap falls back to a local file pointed at by `PBS_SSH_PUBKEY_FILE` when you run it.

### 5. Verify

```bash
rclone cat meta:my-pbs-meta/bootstrap-config.yml
rclone cat meta:my-pbs-meta/authorized_keys
```

Both should return the expected content. If yes, you're DR-ready — proceed only on actual disaster.

## DR usage (the actual recovery)

What you do **when the disaster strikes**.

### 1. Install PVE bare-metal

Standard Proxmox VE installer. During the ceremony:

- Pick disk(s); rootfs ≥ `pbs.rootfs_size + 30 GB`.
- Hostname: match your steady-state name (e.g. `knowsu`).
- **vmbr0 IP + gateway + DNS** — point at your **upstream router** (e.g. `192.168.0.1`), NOT the LAN firewall VM you're recovering (it's gone).
- Set the root password.

### 2. Open PVE web shell

In your browser: `https://<vmbr0-ip>:8006` → log in as `root@pam` → click the node → **Shell**.

All subsequent commands run in this tab. It survives navigation and doesn't require SSH key setup.

### 3. Export B2 credentials

Get the 4 keys from your external password manager and paste:

```bash
export B2_PBS_META_KEY_ID='<meta-key-id>'
export B2_PBS_META_KEY='<meta-app-key>'
export B2_PBS_KEY_ID='<chunks-key-id>'
export B2_PBS_KEY='<chunks-app-key>'
```

Don't save these to a file. `unset` after bootstrap if you stay in the shell.

### 4. Verify the host has internet

```bash
curl -I https://api.backblazeb2.com
```

A `200` or `301` is fine. If this fails, fix the host's upstream first — bootstrap can't help with that.

### 5. Run bootstrap

```bash
curl -sSL https://raw.githubusercontent.com/bigpie1367/pbs-bootstrap/main/bootstrap.sh | bash
```

Or clone first if you'd rather inspect:

```bash
apt install -y git
git clone https://github.com/bigpie1367/pbs-bootstrap /tmp/pbs-bootstrap
/tmp/pbs-bootstrap/bootstrap.sh
```

The script announces each stage with `== name ==` headers. Chunk restore is the long part — expect tens of minutes to many hours depending on bucket size and your egress.

### 6. Verify success

In the web shell:

```bash
pct status <vmid>                                               # → status: running
pct exec <vmid> -- proxmox-backup-manager datastore list        # → your datastore name
pvesm status -storage pbs                                       # → active
```

In PVE GUI: `Datacenter → Storage → pbs` → click → backup browser shows all your backup groups.

Bootstrap is done. See [After bootstrap](#after-bootstrap-operator-handoff) for what's next.

## Configuration — env vars

Defaults are baked in as `: "${VAR:=default}"` shell expansions — override by exporting before running.

Most fields you'll never touch. The ones you might:

- `PBS_META_BUCKET` if your bucket name isn't `siroh-pbs-meta` (the author's default).
- `PBS_REPO_URL` if you forked the repo.
- `PBS_SSH_PUBKEY_FILE` for the very first bootstrap before any `authorized_keys` mirror exists in B2.

| Variable                | Default                                       | What it controls                                          |
|-------------------------|-----------------------------------------------|-----------------------------------------------------------|
| `PBS_TEMPLATE`          | `debian-12-standard_12.7-1_amd64.tar.zst`     | LXC template (must be available via `pveam`).             |
| `PBS_TEMPLATE_STORAGE`  | `local`                                       | Storage holding the template.                              |
| `PBS_IP_CIDR`           | `24`                                          | CIDR appended to the bare IP from config.                  |
| `PBS_SSH_PUBKEY_FILE`   | _none_                                        | Optional fallback file for SSH keys if B2 mirror is empty. |
| `PBS_META_BUCKET`       | `siroh-pbs-meta`                              | B2 bucket holding `bootstrap-config.yml` + `authorized_keys`. |
| `PBS_CONFIG_OBJECT`     | `bootstrap-config.yml`                        | Object key inside the meta bucket.                         |
| `PBS_AUTH_KEYS_OBJECT`  | `authorized_keys`                             | Object key for the SSH keys mirror inside the meta bucket. |
| `PBS_NAT_OUT_IFACE`     | `vmbr0`                                       | Host interface with working upstream (used for MASQUERADE).|
| `PBS_NAT_DNS`           | `1.1.1.1`                                     | Temporary resolver injected into the LXC.                  |
| `PBS_GATEWAY_OVERRIDE`  | _auto-detected from `PBS_BRIDGE`_             | Explicit LXC gateway override during bootstrap.            |
| `PBS_DNS_OVERRIDE`      | _equal to `PBS_NAT_DNS`_                      | Explicit LXC DNS override during bootstrap.                |
| `PBS_GC_SCHEDULE`       | `4:00`                                        | GC schedule written into the freshly registered datastore. |
| `PBS_NOTIFICATION_MODE` | `notification-system`                         | Datastore notification routing.                            |
| `PBS_PVE_USER`          | `pve`                                         | PBS realm user created for PVE auth (`<user>@pbs`).        |
| `PBS_PVE_TOKEN_NAME`    | `pve-backup`                                  | PBS API token name (`<user>@pbs!<token>`).                 |
| `PBS_PVE_ROLE`          | `DatastoreAdmin`                              | ACL role granted on `/datastore/<name>` to user + token.   |
| `PBS_PVE_STORAGE_ID`    | `pbs`                                         | Storage ID used in `/etc/pve/storage.cfg`.                 |

The cores / memory / rootfs values are **not** env vars — they're sourced from `bootstrap-config.yml` so the recovered LXC matches your steady-state declaration exactly.

## Network shim

Bootstrap is a DR tool so it doesn't trust the LAN gateway to be alive. Every run:

1. `sysctl net.ipv4.ip_forward=1` on the host (previous value saved).
2. `iptables -t nat -A POSTROUTING -s <lan-subnet> -o $PBS_NAT_OUT_IFACE -j MASQUERADE`.
3. Creates the LXC with `--nameserver $PBS_NAT_DNS` and `gw=<host bridge IP>` so chunk restore can reach B2 even if the LAN firewall is gone.
4. After chunk restore + datastore setup, runs `pct set --net0 …gw=<config gateway>` so the LXC's declared steady-state network is restored.
5. On exit (success or failure), removes the iptables rule and restores `ip_forward`.

The shim is **always on** during bootstrap and **always torn down** at the end. You don't toggle it.

## Troubleshooting

### Chunk restore is slow

- B2 has class B (download) transaction limits and bandwidth caps depending on your account tier. Check the Backblaze dashboard.
- `--transfers 16 --checkers 32` in `lib/chunks-restore.sh` is tuned for typical home connections. Edit + re-run if you have more bandwidth.

### LXC has no network during bootstrap

```bash
pct exec <vmid> -- ip -4 addr show
pct exec <vmid> -- ip -4 route show
pct exec <vmid> -- cat /etc/resolv.conf
```

Common causes:

- Bridge name drift — `bootstrap-config.yml` says `bridge: vmbr1` but the bridge doesn't exist on the host. Verify `ip link show vmbr1` on the host.
- Masquerade rule missing or wrong out-iface. Check `iptables -t nat -L POSTROUTING -n`.
- DNS not injected — `/etc/resolv.conf` empty. The shim sets `1.1.1.1`; if you customized `PBS_NAT_DNS` to something unreachable from the host, fix it.

### `apt update` fails inside the LXC

Debian 12 LXCs frequently have broken IPv6 default routes. The script forces IPv4 via `/etc/apt/apt.conf.d/99force-ipv4`. If apt **still** fails:

```bash
pct exec <vmid> -- bash -c "curl -4 -I https://deb.debian.org"
```

If that also fails, the LXC's egress is broken — go back to "LXC has no network" above.

### Datastore not visible after bootstrap

```bash
pct exec <vmid> -- journalctl -u proxmox-backup-proxy --no-pager -n 50
pct exec <vmid> -- ls -la /etc/proxmox-backup/
pct exec <vmid> -- ls -la <datastore-path> | head
```

Common causes:

- `datastore.cfg` ownership wrong — must be `root:backup` mode `0640`.
- Chunks under the datastore path still owned by `root` — re-run `pct exec <vmid> -- chown -R backup:backup <datastore-path>`.

### PVE GUI shows backups but `pvesm list pbs` is empty

ACL / ownership issue on the PBS API side. `pbs_auth_setup` grants `DatastoreAdmin` to both `<user>@pbs` and `<user>@pbs!<token>`. If something interrupted that, redo manually:

```bash
pct exec <vmid> -- proxmox-backup-manager acl update \
    /datastore/<name> DatastoreAdmin --auth-id <user>@pbs
pct exec <vmid> -- proxmox-backup-manager acl update \
    /datastore/<name> DatastoreAdmin --auth-id '<user>@pbs!<token>'
```

### `pveam download` fails — template not found

The hardcoded `PBS_TEMPLATE` (defaults to `debian-12-standard_12.7-1_amd64.tar.zst`) may have been replaced by a newer minor version on Proxmox's mirror. Find the current name:

```bash
pveam update
pveam available --section system | grep debian-12-standard
```

Then re-run bootstrap with `PBS_TEMPLATE=<new-name> bash ./bootstrap.sh`.

### LXC already exists

Bootstrap is one-shot and refuses to overwrite an existing VMID. If a previous run failed mid-way:

```bash
pct stop <vmid> --force 2>/dev/null
pct destroy <vmid> --force
```

Then re-run bootstrap. Idempotency-friendly resume isn't implemented.

## After bootstrap (operator handoff)

Bootstrap deliberately stops at "PVE can see PBS". From there, the playbook is yours:

- Set the PBS GUI root password if you want PBS web UI access — `pct exec <vmid> -- passwd root`.
- Restore VMs / CTs from PVE GUI in your preferred order. In a typical "lost everything" DR that's: LAN firewall VM first (so the rest of the homelab gets routable again), then infrastructure (secret manager, monitoring), then application guests.
- Re-arm steady-state automation: nightly B2 chunks sync, prune / verify / GC schedules, notification routing, monitoring. Whatever your normal ansible / terraform / cron did, run it again.

This separation is deliberate. Bootstrap stays useful even for setups very different from ours; restore policy + ongoing operations stay in your repo.

## License

MIT — see [LICENSE](LICENSE).

# pbs-bootstrap

Disaster-recover a [Proxmox Backup Server](https://www.proxmox.com/en/proxmox-backup-server) LXC from Backblaze B2 cold storage.

Designed for the case where you've lost everything except your B2 bucket: bare-metal Proxmox VE host, no terraform state, no ansible repo. As long as you have your B2 credentials and a config file in the meta bucket, this script gets the PBS LXC back to a working state.

## What it does

1. Pulls `bootstrap-config.yml` from the B2 *meta* bucket — VMID, hostname, network, datastore path.
2. Creates an unprivileged Debian 12 LXC on the Proxmox host (`pct create`).
3. Installs `proxmox-backup-server` inside the LXC (no-subscription repo).
4. Restores chunks from the B2 *chunks* bucket via `rclone copy` (foreground, with progress).
5. Drops `/etc/proxmox-backup/datastore.cfg` so PBS adopts the restored layout — no fresh-init, no data loss.

What it does *not* do — these are intentionally out of scope so the script stays useful to anyone, not just our homelab:

- PVE → PBS storage entry sync (`pvesm set …`)
- API user / token / ACL setup
- Continuous B2 sync cron
- Prune / verify schedules
- GUI root password — set manually after first boot.

Those are handled separately by the [homelab ansible role](https://github.com/bigpie1367/homelab/tree/main/ansible/roles/pbs).

## Requirements

- Proxmox VE host (anything that ships `pct` and `pveam`).
- Network egress to B2 from the Proxmox host *and* from the new LXC.
- Two B2 application keys with narrow scope:
  - One read-only on the *chunks* bucket.
  - One read-write on the *meta* bucket (or read-only if you don't need ansible to update the config).
- An SSH pubkey to inject into the LXC (defaults to `~/.ssh/authorized_keys` on the host).
- `bootstrap-config.yml` already present in your meta bucket. Format:

  ```yaml
  pbs:
    vmid:     200
    hostname: pbs
    bridge:   vmbr0
    ip:       10.80.60.200
    gateway:  10.80.60.1
    datastore_name: system-backup
    datastore_path: /mnt/pbs_backup
  b2:
    chunks_bucket: my-pbs-chunks
    meta_bucket:   my-pbs-meta
  ```

  In our homelab this is rendered automatically by the ansible role on every apply.

## Usage

On the Proxmox host (`tmux` / `screen` recommended — chunk restore can take hours):

```bash
export B2_PBS_META_KEY_ID=...  B2_PBS_META_KEY=...
export B2_PBS_KEY_ID=...       B2_PBS_KEY=...

curl -sSL https://raw.githubusercontent.com/bigpie1367/pbs-bootstrap/main/bootstrap.sh | bash
```

Or clone first:

```bash
git clone https://github.com/bigpie1367/pbs-bootstrap
cd pbs-bootstrap
./bootstrap.sh
```

## Configuration

Defaults are baked in as `: "${VAR:=default}"` shell expansions — override by exporting before running.

| Variable                | Default                                       | What it controls                                          |
|-------------------------|-----------------------------------------------|-----------------------------------------------------------|
| `PBS_TEMPLATE`          | `debian-12-standard_12.7-1_amd64.tar.zst`     | LXC template (must be available via `pveam`).             |
| `PBS_TEMPLATE_STORAGE`  | `local`                                       | Storage holding the template.                              |
| `PBS_ROOTFS_STORAGE`    | `local-lvm`                                   | Storage backing the LXC rootfs.                            |
| `PBS_ROOTFS_SIZE`       | `64` (GB)                                     | Must be large enough to hold restored chunks.              |
| `PBS_MEMORY`            | `2048` (MB)                                   | LXC RAM allocation.                                        |
| `PBS_CORES`             | `2`                                           | LXC CPU cores.                                             |
| `PBS_IP_CIDR`           | `24`                                          | CIDR appended to the bare IP from config.                  |
| `PBS_SSH_PUBKEY_FILE`   | `$HOME/.ssh/authorized_keys`                  | SSH pubkey injected at LXC create time.                    |
| `PBS_META_BUCKET`       | `siroh-pbs-meta`                              | B2 bucket holding `bootstrap-config.yml`.                  |
| `PBS_CONFIG_OBJECT`     | `bootstrap-config.yml`                        | Object key inside the meta bucket.                         |
| `PBS_GC_SCHEDULE`       | `4:00`                                        | Datastore GC schedule.                                     |
| `PBS_NOTIFICATION_MODE` | `notification-system`                         | PBS notification routing.                                  |

## After bootstrap

1. Set a GUI root password: `pct exec <vmid> -- passwd root`.
2. Log into `https://<pbs-ip>:8007` and confirm the datastore is visible with all backup groups.
3. If you're integrating with PVE, wire up the storage entry (`pvesm set pbs --username ... --password ... --fingerprint ...`) — or run the homelab ansible role which does this idempotently.

## DR runbook

See [docs/DR-runbook.md](docs/DR-runbook.md) for a step-by-step recovery walkthrough including troubleshooting.

## License

MIT.

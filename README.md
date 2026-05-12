# pbs-bootstrap

Disaster-recover a [Proxmox Backup Server](https://www.proxmox.com/en/proxmox-backup-server) LXC from Backblaze B2 cold storage.

Designed for the case where you've lost everything except your B2 bucket: bare-metal Proxmox VE host, no terraform state, no ansible repo. As long as you have your B2 credentials and a config file in the meta bucket, this script gets the PBS LXC back to a working state.

## What it does

1. Pulls `bootstrap-config.yml` from the B2 *meta* bucket — VMID, hostname, network, datastore path.
2. Creates an unprivileged Debian 12 LXC on the Proxmox host (`pct create`).
3. Installs `proxmox-backup-server` inside the LXC (no-subscription repo).
4. Restores chunks from the B2 *chunks* bucket via `rclone copy` (foreground, with progress), `chown`ed to `backup:backup`.
5. Registers the datastore with PBS (`/etc/proxmox-backup/datastore.cfg`).
6. Creates a PBS API user + token + `DatastoreAdmin` ACL.
7. Adds a PBS storage entry to PVE (`/etc/pve/storage.cfg`) using the new token + the PBS TLS fingerprint.

After step 7 you have a working PVE → PBS chain. From the PVE GUI you can browse the restored backup groups and restore any VM/CT — typically your **LAN firewall VM first** so the rest of the homelab can be brought back by your normal IaC tooling.

Out of scope (handled by your post-bootstrap ansible/terraform):

- Continuous B2 sync cron, prune / verify / GC schedules.
- Datastore notification settings beyond the bare minimum.
- GUI root password.
- Restoring the LAN gateway VM itself.

The scope is set by the DR chicken-and-egg: in a real disaster the LAN firewall is also down, so your normal automation (which depends on the firewall for VPN access) can't reach the host. Bootstrap does *just enough* in-place that you can use the PVE GUI to restore the firewall, and from there everything else follows.

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

### Network shim (always-on, transparent)

Bootstrap is a disaster-recovery tool, so it doesn't trust the LAN gateway to be alive. Every run:

1. `sysctl net.ipv4.ip_forward=1` on the host (previous value saved).
2. `iptables -t nat -A POSTROUTING -s <lan-subnet> -o $PBS_NAT_OUT_IFACE -j MASQUERADE`.
3. Creates the LXC with `--nameserver $PBS_NAT_DNS` and `gw=<host bridge IP>` so chunk restore can reach B2 even if the LAN firewall is gone.
4. After chunk restore completes, runs `pct set --net0 …gw=<config gateway>` so the LXC's declared steady-state network is restored.
5. On exit (success or failure), removes the iptables rule and restores `ip_forward`.

Prerequisite: the **Proxmox host itself** must have working internet that does not depend on the dead LAN gateway — typically true if the host's default route points to an upstream router (consumer router, ISP modem) rather than the LAN firewall VM you're recovering from. Verify with `curl -I https://api.backblazeb2.com` on the host before running bootstrap.

## After bootstrap

You should now have:
- PBS LXC up, root password unset
- Datastore registered, all backup groups visible in the PBS GUI
- PBS API user + token created
- PVE storage entry `pbs` wired to PBS with valid TLS fingerprint + token credentials

Manual steps from here:

1. Set the PBS GUI root password — `pct exec <vmid> -- passwd root`.
2. Open the PVE GUI, find your LAN firewall VM under the `pbs` storage's backup browser, and restore it. Once that VM is up, the rest of the homelab gets internet back and your normal IaC (terraform + ansible) can take over.
3. Restore everything else from PBS as needed.

Your ongoing automation (B2 sync cron, prune/verify/GC schedules, monitoring, etc.) lives in your usual ansible role, not here. Apply it once GHA can reach the host again.

## DR runbook

See [docs/DR-runbook.md](docs/DR-runbook.md) for a step-by-step recovery walkthrough including troubleshooting.

## License

MIT.

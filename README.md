# pbs-bootstrap

Disaster-recover a [Proxmox Backup Server](https://www.proxmox.com/en/proxmox-backup-server) LXC from Backblaze B2 cold storage.

Designed for the case where you've lost everything except your B2 bucket: bare-metal Proxmox VE host, no terraform state, no ansible repo. As long as you have your B2 credentials and a config file in the meta bucket, this script gets the PBS LXC back to a working state.

## What it does

1. Fixes the Proxmox host's apt repos (pve-enterprise → pve-no-subscription) and installs deps (rclone, yq, iptables, ifupdown2).
2. Configures rclone B2 remotes on the host and pulls `bootstrap-config.yml` from the meta bucket.
3. Materializes the host's additional bridges (`host.bridges[*]` from config — typically vmbr1) into `/etc/network/interfaces.d/` and reloads.
4. Fetches the operator's `authorized_keys` from B2 meta and installs it on the host + stages it for LXC injection.
5. Enables host-side `iptables` MASQUERADE so the new LXC has internet even with the LAN firewall down.
6. Creates an unprivileged Debian 12 LXC on the Proxmox host (`pct create`) sized to `pbs.rootfs_*` from config.
7. Installs `proxmox-backup-server` inside the LXC.
8. Restores chunks from the B2 *chunks* bucket via `rclone copy` (foreground, with progress), `chown`ed to `backup:backup`.
9. Registers the datastore with PBS (`/etc/proxmox-backup/datastore.cfg`).
10. Creates a PBS API user + token + `DatastoreAdmin` ACL.
11. Adds a PBS storage entry to PVE (`/etc/pve/storage.cfg`) using the new token + the PBS TLS fingerprint.
12. Restores the LXC's network to the declared steady-state gateway + tears down the host masquerade.

After step 11 you have a working PVE → PBS chain. From the PVE GUI you can browse the restored backup groups and restore any VM/CT — typically your **LAN firewall VM first** so the rest of the homelab can be brought back by your normal IaC tooling.

Out of scope (handled by your post-bootstrap ansible/terraform):

- Continuous B2 sync cron, prune / verify / GC schedules.
- Datastore notification settings beyond the bare minimum.
- GUI root password.
- Restoring the LAN gateway VM itself.

The scope is set by the DR chicken-and-egg: in a real disaster the LAN firewall is also down, so your normal automation (which depends on the firewall for VPN access) can't reach the host. Bootstrap does *just enough* in-place that you can use the PVE GUI to restore the firewall, and from there everything else follows.

## Requirements

- Proxmox VE host (fresh install OK — the installer's network ceremony provides vmbr0 with internet).
- Network egress to B2 from the Proxmox host.
- Two B2 application keys with narrow scope:
  - Chunks bucket: read-only is enough for the script itself; read-write is needed for steady-state syncs (out of scope here).
  - Meta bucket: read-only is enough during bootstrap; read-write is needed for ansible-driven mirror updates.
- `bootstrap-config.yml` already present in your meta bucket. Format:

  ```yaml
  pbs:
    vmid:           200
    hostname:       pbs
    bridge:         vmbr1
    ip:             10.80.60.200
    gateway:        10.80.60.1
    datastore_name: system-backup
    datastore_path: /mnt/pbs_backup
    rootfs_size:    100
    rootfs_storage: local
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

  The `host.bridges` section defines bridges the host needs *in addition to* vmbr0 (which the PVE installer already created). vmbr0 is intentionally absent from this section — bootstrap doesn't touch it.

- `authorized_keys` mirror in the meta bucket (optional but recommended): a plain-text file with one SSH public key per line. Used to seed both the host's `/root/.ssh/authorized_keys` and the new PBS LXC. Without it, bootstrap falls back to `$PBS_SSH_PUBKEY_FILE` (env var pointing at a local file).

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
| `PBS_MEMORY`            | `2048` (MB)                                   | LXC RAM allocation.                                        |
| `PBS_CORES`             | `2`                                           | LXC CPU cores.                                             |
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

[English](README.md) | [한국어](README.ko.md)

# pbs-bootstrap

One-command DR for a [Proxmox Backup Server](https://www.proxmox.com/en/proxmox-backup-server) LXC: fresh PVE install → PVE GUI can browse your backups. Interactive TUI by default; env vars for automation.

## Quickstart

In the PVE web shell:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/bigpie1367/pbs-bootstrap/main/bootstrap.sh)
```

Answer the prompts. Done when `pvesm status -storage pbs` is `active` and the PVE GUI's `pbs` storage shows your backup groups.

**Prereqs**

- Fresh PVE host — `vmbr0` pointed at your upstream router (consumer router / ISP modem), not the LAN firewall VM you're recovering.
- Chunks bucket key — B2 native or any S3-compatible (AWS, MinIO, R2, Wasabi, B2 via S3).
- Somewhere to host `bootstrap-config.yml` + your SSH keys — GitHub repo, B2/S3 bucket, or local file.

## Pipeline

| # | Stage | What it does | Time |
|---|---|---|---|
| 1 | preflight | validate env vars / required deps / PVE host | <1s |
| 2 | host-apt | swap `pve-enterprise` → `pve-no-subscription`, install `rclone yq iptables ifupdown2` | ~30s |
| 3 | rclone-setup | write `/root/.config/rclone/rclone.conf` (chunks + optional meta remote) | <1s |
| 4 | config-pull | resolve `PBS_CONFIG` → `/tmp/bootstrap-config.yml` (b2/s3/github/url/file/paste) | <2s |
| 5 | host-network | render `/etc/network/interfaces.d/<bridge>.conf` for each `host.bridges[*]`, `ifreload -a` (vmbr0 untouched) | ~5s |
| 6 | auth-keys | resolve `PBS_AUTH_KEYS` → host `/root/.ssh/authorized_keys` + stage for LXC injection | <2s |
| 7 | network-shim | `sysctl ip_forward=1` + `iptables -t nat MASQUERADE` for LXC subnet → vmbr0 | <1s |
| 8 | lxc-create | `pveam download` template if missing, `pct create` + `pct start` (gateway/DNS overridden) | ~30s |
| 9 | pbs-install | inside LXC: ForceIPv4 apt, `pve-no-subscription`, install `proxmox-backup-server` | ~1–2min |
| 10 | chunks-restore | inside LXC: `rclone copy chunks:<bucket> <datastore-path>`, `chown -R backup:backup` | **hours** |
| 11 | datastore-init | write `/etc/proxmox-backup/datastore.cfg`, reload `proxmox-backup-proxy` | <2s |
| 12 | pbs-auth | `proxmox-backup-manager user create` + `generate-token` + `acl update` (DatastoreAdmin) | ~5s |
| 13 | pve-storage | extract PBS TLS fingerprint, `pvesm add\|set pbs --server <ip> --fingerprint … --username …` | ~3s |
| 14 | network-restore | `pct set --net0 gw=<declared>`, then iptables/sysctl teardown via trap | <2s |

10 dominates wall-clock (chunks bucket size × egress bandwidth). Everything else is seconds to a minute.

## `bootstrap-config.yml`

```yaml
pbs:
  vmid:             200
  hostname:         pbs
  bridge:           vmbr1
  ip:               10.80.60.200
  gateway:          10.80.60.1
  datastore_name:   system-backup
  datastore_path:   /mnt/pbs_backup
  rootfs_size:      100
  rootfs_storage:   local
  cores:            2
  memory_dedicated: 2048
  memory_swap:      1024

host:
  bridges:                                # vmbr0 omitted — installer owns it
    - name:         vmbr1
      address:      10.80.60.254/24
      bridge_ports: none
      static_routes:
        - { subnet: 10.80.80.0/24, gateway: 10.80.60.1 }

storage:
  type:          b2                       # b2 | s3
  # endpoint:    https://...              # required when type=s3
  # region:      us-east-005              # required when type=s3
  chunks_bucket: my-pbs-chunks
```

## Non-interactive (CI / re-run)

```bash
export PBS_STORAGE_TYPE=b2
export PBS_CHUNKS_KEY_ID=... PBS_CHUNKS_KEY=...
export PBS_CONFIG=b2://my-pbs-meta/bootstrap-config.yml
export PBS_AUTH_KEYS=b2://my-pbs-meta/authorized_keys
export PBS_META_KEY_ID=...   PBS_META_KEY=...     # only if any source is b2:// or s3://

bash bootstrap.sh
```

Source URI forms (`PBS_CONFIG` and `PBS_AUTH_KEYS`):

| Form | Notes |
|---|---|
| `b2://<bucket>/<path>` · `s3://<bucket>/<path>` | meta credentials required |
| `github:<owner>/<repo>/<branch>/<path>` | `PBS_<KIND>_GITHUB_PAT` for private |
| `https://...` | raw HTTP fetch |
| `/abs/path` · `./path` | local file |
| `<user>` (bare word) | `auth_keys` only — `github.com/<user>.keys` |
| `skip` | `auth_keys` only — no SSH injection |

Partial env works too — TUI prompts for whatever's missing.

## Troubleshooting

<details><summary><b>Chunk restore is slow</b></summary>

B2 has class B (download) caps — check the dashboard. Bump `--transfers` / `--checkers` in `lib/chunks-restore.sh` for fatter uplinks.
</details>

<details><summary><b>LXC has no network during bootstrap</b></summary>

```bash
pct exec <vmid> -- ip -4 addr show
pct exec <vmid> -- ip -4 route show
pct exec <vmid> -- cat /etc/resolv.conf
```

Most common causes: bridge name drift, masquerade rule missing, DNS not injected.
</details>

<details><summary><b>Datastore not visible after bootstrap</b></summary>

`datastore.cfg` must be `root:backup 0640`; chunks must be `backup:backup`. Re-run `chown -R backup:backup <datastore-path>` if needed.
</details>

<details><summary><b>PVE GUI sees backups but <code>pvesm list pbs</code> is empty</b></summary>

```bash
pct exec <vmid> -- proxmox-backup-manager acl update \
    /datastore/<name> DatastoreAdmin --auth-id '<user>@pbs!<token>'
```
</details>

<details><summary><b><code>pveam download</code> fails — template not found</b></summary>

```bash
pveam available --section system | grep debian-12-standard
```

Re-run with `PBS_TEMPLATE=<new-name> bash bootstrap.sh`.
</details>

<details><summary><b>LXC already exists</b></summary>

Bootstrap is one-shot. `pct destroy <vmid> --force`, then retry.
</details>

## License

MIT — see [LICENSE](LICENSE).

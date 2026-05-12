# DR Runbook — recovering PBS from B2

Use this when the PBS LXC is gone (host wiped, container destroyed, storage lost) and you need to get it back from B2 cold storage.

## Prerequisites

Before you start, gather:

- [ ] **B2 credentials** — two key pairs (meta bucket, chunks bucket). If you don't have these, recovery is impossible — you can't get past step 1.
- [ ] **Proxmox host** — fresh or existing, reachable on the network with the same bridge/gateway as the lost LXC.
- [ ] **SSH access** to the Proxmox host.
- [ ] **Enough free storage** for the rootfs (default 64 GB) on the LXC's backing pool.

## Step-by-step

### 1. SSH to the Proxmox host

```bash
ssh root@<proxmox-host>
```

Start a `tmux` or `screen` session — chunk restore is long-running and you don't want a dropped SSH connection to interrupt it.

```bash
tmux new -s pbs-recover
```

### 2. Export B2 credentials

```bash
export B2_PBS_META_KEY_ID='<meta-key-id>'
export B2_PBS_META_KEY='<meta-app-key>'
export B2_PBS_KEY_ID='<chunks-key-id>'
export B2_PBS_KEY='<chunks-app-key>'
```

Do **not** save these to a file on disk. After the run, `unset` them.

### 3. Run bootstrap

```bash
curl -sSL https://raw.githubusercontent.com/bigpie1367/pbs-bootstrap/main/bootstrap.sh | bash
```

The script will:

1. Validate env + deps (a few seconds).
2. Install rclone on the host and pull `bootstrap-config.yml`.
3. Download the Debian template if missing.
4. `pct create` the LXC and start it.
5. Install PBS inside the LXC.
6. **Restore chunks** — this is the long part. Expect 10s of minutes to many hours depending on bucket size and your egress.
7. Write `datastore.cfg` and reload the proxy.

### 4. Set the root password

```bash
pct exec <vmid> -- passwd root
```

(VMID is printed at the end of the bootstrap run, or visible in `bootstrap-config.yml`.)

### 5. Verify

Open `https://<pbs-ip>:8007` in a browser. Log in as `root@pam`. Check:

- [ ] Datastore appears in the sidebar.
- [ ] Backup groups list (VMs / CTs) shows all your previous snapshots.
- [ ] Pick one snapshot, browse it — files should be readable.
- [ ] `proxmox-backup-manager garbage-collection list` returns the datastore (no errors).

### 6. Re-integrate with PVE (homelab-specific)

If you also lost your PVE storage entry, run the homelab ansible role to recreate the API user / token and update `/etc/pve/storage.cfg` with the new TLS fingerprint:

```bash
cd ~/homelab
ansible-playbook ansible/playbooks/pbs.yml
```

### 7. Re-arm scheduled tasks

- Prune / verify / GC schedules are written by the homelab ansible role, not bootstrap. Run the role.
- B2 sync cron likewise.

## Troubleshooting

### Chunk restore is slow

- B2 free tier has download caps. Check your account dashboard.
- `--transfers` / `--checkers` in `lib/chunks-restore.sh` are tuned for a typical home connection. Bump if you have more bandwidth.

### LXC has no network

```bash
pct exec <vmid> -- ip a
pct exec <vmid> -- ip route
```

Verify the bridge in `bootstrap-config.yml` exists on the new host. Common cause: bridge name drift (`vmbr0` vs `vmbr1`) after a host reinstall.

### `apt update` fails inside LXC

Debian 12 LXC IPv6 routes are frequently broken. The script forces IPv4 via `/etc/apt/apt.conf.d/99force-ipv4`. If apt *still* fails:

```bash
pct exec <vmid> -- bash -c "curl -4 -I https://deb.debian.org"
```

If that fails too, the LXC network is misconfigured at the bridge / gateway level — fix at the host before retrying.

### Datastore not visible after bootstrap

```bash
pct exec <vmid> -- journalctl -u proxmox-backup-proxy --no-pager -n 50
pct exec <vmid> -- ls -la /etc/proxmox-backup/
pct exec <vmid> -- ls -la <datastore-path> | head
```

Most common causes:

- `datastore.cfg` ownership is wrong (must be `root:backup` mode `0640`).
- Chunks under the datastore path are still owned by `root` — re-run `chown -R backup:backup <path>`.

### Backups visible but I can't list them

If `pvesm list pbs` returns empty but the GUI shows snapshots, that's an ACL / ownership issue on the API side — out of scope for bootstrap, handled by the homelab ansible role's `DatastoreAdmin` grant.

## What to do *before* a disaster

Bootstrap can only recover what's in B2 when the disaster strikes. Verify the meta bucket has a current `bootstrap-config.yml`:

```bash
rclone cat meta:siroh-pbs-meta/bootstrap-config.yml
```

If the file is stale (VMID / IP / bridge differs from production), running bootstrap will recreate the LXC with the wrong values. Re-run the homelab ansible role to refresh it.

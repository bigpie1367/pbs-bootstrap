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

In a true DR scenario these keys are unreachable from your homelab secret manager (which is also dead). Recovery is only possible if you stored them somewhere outside the homelab — a personal password manager, encrypted USB, or paper backup. If you have not done this yet and your homelab is still up, do it **now**.

### 3. Verify host has internet (independent of LAN gateway)

In a real disaster the LAN gateway (pfSense / OPNsense / etc.) is also gone, so the new PBS LXC won't have a path to B2 through it. Bootstrap works around this by NAT-ing LXC traffic through the Proxmox host — which only works if the **host** still has internet via a different upstream (consumer router, ISP modem, etc.).

Confirm before continuing:

```bash
curl -I https://api.backblazeb2.com
```

If that fails, the host itself is offline. Fix that before running bootstrap — neither the script nor any other DR step can do anything useful until the host can reach B2.

### 4. Run bootstrap

```bash
curl -sSL https://raw.githubusercontent.com/bigpie1367/pbs-bootstrap/main/bootstrap.sh | bash
```

The script will:

1. Validate env + deps (a few seconds).
2. Install rclone on the host and pull `bootstrap-config.yml`.
3. Apply the temporary host-side NAT (so the new LXC has a path to B2 even with the LAN firewall down).
4. Download the Debian template if missing.
5. `pct create` the LXC and start it (with `gw=<host bridge IP>`, `--nameserver 1.1.1.1`).
6. Install PBS inside the LXC.
7. **Restore chunks** — long-running. Expect 10s of minutes to many hours depending on bucket size and your egress.
8. Register the datastore by writing `/etc/proxmox-backup/datastore.cfg` and reloading the proxy.
9. Create the PBS API user + token + `DatastoreAdmin` ACL.
10. Add the PVE storage entry pointing at PBS (with the freshly-captured token + TLS fingerprint).
11. `pct set --net0` back to the declared gateway so the LXC's network config matches `bootstrap-config.yml`.
12. Tear down the host-side NAT.

When the script returns, PBS is fully wired into PVE — you can immediately browse backups in the PVE GUI and start restores.

### 5. Set the root password

```bash
pct exec <vmid> -- passwd root
```

(VMID is printed at the end of the bootstrap run, or visible in `bootstrap-config.yml`.)

### 6. Verify PBS ↔ PVE chain

Open the PBS GUI at `https://<pbs-ip>:8007` (`root@pam`) and confirm:

- [ ] Datastore appears in the sidebar with the expected name.
- [ ] Backup groups list (VM/CT) shows your previous snapshots.

Open the PVE GUI and confirm:

- [ ] Storage `pbs` (or whatever `PBS_PVE_STORAGE_ID` you set) appears as a backup storage.
- [ ] Browsing the `pbs` storage shows the same backup groups.

If both look right, you're ready to restore.

### 7. Restore the LAN firewall VM from PVE

This is the critical first restore. While the LAN firewall VM is gone, the LXC has no outbound internet (only LAN-local reachability via the host's masquerade — which bootstrap has already torn down) and GHA / WireGuard can't reach the host to drive automation.

In the PVE GUI:

1. Browse the `pbs` storage, locate your firewall VM's last backup.
2. Restore it to the appropriate node, keeping its original VMID and network config.
3. Start it. Confirm it picks up its old LAN IP and starts answering.

Once the firewall is back up the rest of the homelab regains internet and your normal IaC tooling can drive the recovery of everything else.

### 8. Hand off to your IaC

With the firewall back, run your normal `terraform apply` + ansible playbooks to:

- Restore the remaining LXCs / VMs from PBS.
- Re-arm B2 sync cron, prune / verify / GC schedules.
- Set up notifications, monitoring, etc.

In our homelab this is `ansible-playbook ansible/playbooks/pbs.yml` followed by the broader site-wide play.

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

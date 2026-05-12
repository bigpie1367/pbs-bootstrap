# DR Runbook — recovering PBS from B2

Use this when the PBS LXC is gone (host wiped, container destroyed, storage lost) and you need to get it back from B2 cold storage.

## Prerequisites

Before you start, gather:

- [ ] **B2 credentials** — two key pairs (meta bucket, chunks bucket). If you don't have these, recovery is impossible.
- [ ] **Proxmox host** — fresh PVE bare-metal install. During the installer ceremony, set vmbr0 IP / gateway so the host can reach the internet via your upstream router (NOT the LAN firewall VM you're recovering from).
- [ ] **PVE web shell or console** access — root password set during install. SSH key access on the host isn't needed: bootstrap will install the operator keys from B2 mirror as it runs.
- [ ] **Enough free storage** for the LXC rootfs on the storage pool referenced in `bootstrap-config.yml` (homelab default: 100 GB on `local`).

## Step-by-step

### 1. Open a shell on the Proxmox host

Browser → `https://<vmbr0-ip>:8006` → log in as `root@pam` → click the host node → **Shell**.

All subsequent commands run in this shell. It survives across PVE GUI navigation, and chunk restore (long-running) is safe inside it.

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

1. Validate env + deps.
2. Fix the host's apt repos (pve-enterprise → pve-no-subscription) and install rclone / yq / iptables / ifupdown2.
3. Configure rclone B2 remotes and pull `bootstrap-config.yml`.
4. Create the host's additional bridges (`host.bridges[*]` — typically vmbr1) into `/etc/network/interfaces.d/` and reload networking.
5. Fetch `authorized_keys` from the B2 meta mirror, install it on the host, and stage it for LXC injection.
6. Apply the temporary host-side MASQUERADE so the new LXC has a path to B2 even with the LAN firewall down.
7. Download the Debian template if missing.
8. `pct create` the LXC and start it (with `gw=<host bridge IP>`, `--nameserver 1.1.1.1`).
9. Install PBS inside the LXC.
10. **Restore chunks** — long-running. Expect 10s of minutes to many hours depending on bucket size and your egress.
11. Register the datastore by writing `/etc/proxmox-backup/datastore.cfg` and reloading the proxy.
12. Create the PBS API user + token + `DatastoreAdmin` ACL.
13. Add the PVE storage entry pointing at PBS (with the freshly-captured token + TLS fingerprint).
14. `pct set --net0` back to the declared gateway so the LXC's network config matches `bootstrap-config.yml`.
15. Tear down the host-side MASQUERADE.

When the script returns, PBS is fully wired into PVE — you can immediately browse backups in the PVE GUI.

### 5. Confirm success

Quick sanity in the PVE web shell:

```bash
pct status <vmid>                                              # → status: running
pct exec <vmid> -- proxmox-backup-manager datastore list       # → your datastore
pvesm status -storage pbs                                      # → active
```

PVE GUI: `Datacenter → Storage → pbs` should show your backup groups when browsed.

If all three check out, bootstrap is done. What you do next — restore order, GUI password, schedules, sync setup — is your operator playbook, not this script's concern.

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

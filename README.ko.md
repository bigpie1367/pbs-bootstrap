[English](README.md) | [한국어](README.ko.md)

# pbs-bootstrap

Proxmox Backup Server LXC 한 줄 DR: 베어메탈 PVE 설치 직후 → PVE GUI 에서 백업 browse 가능 상태. 기본은 인터랙티브 TUI, env var 로 자동화 가능.

## 빠른 실행

PVE 웹쉘에서:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/bigpie1367/pbs-bootstrap/main/bootstrap.sh)
```

프롬프트 응답 → 끝. `pvesm status -storage pbs` 가 `active` 면 OK, PVE GUI 의 `pbs` storage 에 backup 그룹 보임.

**전제조건**

- PVE 호스트 — `vmbr0` 가 공유기 (또는 ISP 모뎀) 가리킴, 복구 대상인 LAN firewall VM 이 아닌.
- Chunks bucket 키 — B2 native 또는 S3-compatible (AWS, MinIO, R2, Wasabi, B2 via S3).
- `bootstrap-config.yml` + SSH 키 둘 곳 — GitHub repo, B2/S3 bucket, 또는 로컬 파일.

## 파이프라인

| # | 단계 | 하는 일 | 시간 |
|---|---|---|---|
| 1 | preflight | env vars / 의존성 / PVE 호스트 검증 | <1s |
| 2 | host-apt | `pve-enterprise` → `pve-no-subscription` 교체, `rclone yq iptables ifupdown2` 설치 | ~30s |
| 3 | rclone-setup | `/root/.config/rclone/rclone.conf` 작성 (chunks + 선택적 meta remote) | <1s |
| 4 | config-pull | `PBS_CONFIG` 해석 → `/tmp/bootstrap-config.yml` (b2/s3/github/url/file/paste) | <2s |
| 5 | host-network | `host.bridges[*]` 별로 `/etc/network/interfaces.d/<bridge>.conf` 렌더 + `ifreload -a` (vmbr0 안 건드림) | ~5s |
| 6 | auth-keys | `PBS_AUTH_KEYS` 해석 → 호스트 `/root/.ssh/authorized_keys` + LXC 주입용 stage | <2s |
| 7 | network-shim | `sysctl ip_forward=1` + `iptables -t nat MASQUERADE` (LXC subnet → vmbr0) | <1s |
| 8 | lxc-create | 템플릿 없으면 `pveam download`, `pct create` + `pct start` (gateway/DNS override) | ~30s |
| 9 | pbs-install | LXC 안: ForceIPv4 apt, `pve-no-subscription`, `proxmox-backup-server` 설치 | ~1–2분 |
| 10 | chunks-restore | LXC 안: `rclone copy chunks:<bucket> <datastore-path>`, `chown -R backup:backup` | **수 시간** |
| 11 | datastore-init | `/etc/proxmox-backup/datastore.cfg` 작성, `proxmox-backup-proxy` reload | <2s |
| 12 | pbs-auth | `proxmox-backup-manager user create` + `generate-token` + `acl update` (DatastoreAdmin) | ~5s |
| 13 | pve-storage | PBS TLS fingerprint 추출, `pvesm add\|set pbs --server <ip> --fingerprint … --username …` | ~3s |
| 14 | network-restore | `pct set --net0 gw=<declared>`, iptables/sysctl trap teardown | <2s |

10번이 wall-clock 의 대부분 (chunks bucket 크기 × egress 대역폭). 나머진 다 초 단위.

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
  bridges:                                # vmbr0 빠짐 — 설치 ceremony 가 만듦
    - name:         vmbr1
      address:      10.80.60.254/24
      bridge_ports: none
      static_routes:
        - { subnet: 10.80.80.0/24, gateway: 10.80.60.1 }

storage:
  type:          b2                       # b2 | s3
  # endpoint:    https://...              # type=s3 일 때 필수
  # region:      us-east-005              # type=s3 일 때 필수
  chunks_bucket: my-pbs-chunks
```

## 비대화식 (CI / 재실행)

```bash
export PBS_STORAGE_TYPE=b2
export PBS_CHUNKS_KEY_ID=... PBS_CHUNKS_KEY=...
export PBS_CONFIG=b2://my-pbs-meta/bootstrap-config.yml
export PBS_AUTH_KEYS=b2://my-pbs-meta/authorized_keys
export PBS_META_KEY_ID=...   PBS_META_KEY=...     # b2://·s3:// 출처 있을 때만

bash bootstrap.sh
```

`PBS_CONFIG` / `PBS_AUTH_KEYS` 가 받는 형태:

| 형태 | 비고 |
|---|---|
| `b2://<bucket>/<path>` · `s3://<bucket>/<path>` | meta 키 필요 |
| `github:<owner>/<repo>/<branch>/<path>` | private 이면 `PBS_<KIND>_GITHUB_PAT` |
| `https://...` | raw HTTP fetch |
| `/abs/path` · `./path` | 로컬 파일 |
| `<user>` (단어) | `auth_keys` 만 — `github.com/<user>.keys` |
| `skip` | `auth_keys` 만 — SSH 키 안 박음 |

일부 env 만 set 해도 TUI 가 나머지 물어봄.

## 트러블슈팅

<details><summary><b>chunks 복원이 너무 느려</b></summary>

B2 class B (download) 한도 — Backblaze dashboard 확인. `lib/chunks-restore.sh` 의 `--transfers` / `--checkers` 올려서 재시도.
</details>

<details><summary><b>부트스트랩 중 LXC 가 네트워크 없음</b></summary>

```bash
pct exec <vmid> -- ip -4 addr show
pct exec <vmid> -- ip -4 route show
pct exec <vmid> -- cat /etc/resolv.conf
```

흔한 원인: bridge 이름 drift, masquerade 룰 누락, DNS 미주입.
</details>

<details><summary><b>부트스트랩 끝났는데 datastore 가 안 보여</b></summary>

`datastore.cfg` 는 `root:backup 0640`, chunks 는 `backup:backup`. `chown -R backup:backup <datastore-path>` 재실행.
</details>

<details><summary><b>PVE GUI 엔 backup 보이는데 <code>pvesm list pbs</code> 가 비어있음</b></summary>

```bash
pct exec <vmid> -- proxmox-backup-manager acl update \
    /datastore/<name> DatastoreAdmin --auth-id '<user>@pbs!<token>'
```
</details>

<details><summary><b><code>pveam download</code> 가 템플릿 못 찾음</b></summary>

```bash
pveam available --section system | grep debian-12-standard
```

찾은 이름으로 `PBS_TEMPLATE=<새-이름> bash bootstrap.sh` 재실행.
</details>

<details><summary><b>LXC 이미 존재</b></summary>

부트스트랩은 one-shot. `pct destroy <vmid> --force` 후 재시도.
</details>

## License

MIT — [LICENSE](LICENSE) 참고.

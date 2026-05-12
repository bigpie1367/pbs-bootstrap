[English](README.md) | [한국어](README.ko.md)

# pbs-bootstrap

PVE 베어메탈 다시 깐 뒤 한 줄 명령으로 Proxmox Backup Server LXC 를 Backblaze B2 cold mirror 에서 되살려주는 DR 스크립트.

> ⚠️ DR 시점 한 번 돌리는 도구. PBS 를 B2 와 평상시 동기화하는 건 steady-state 영역 (cron / ansible 등), 이 스크립트가 할 일 아님.

## 목차

- [언제 쓰나](#언제-쓰나)
- [bootstrap.sh 가 하는 일](#bootstrapsh-가-하는-일)
- [전제조건](#전제조건)
- [최초 셋업](#최초-셋업) (DR 전에 한 번)
- [DR 절차](#dr-절차)
- [환경변수](#환경변수)
- [네트워크 shim 이 뭐 하는지](#네트워크-shim-이-뭐-하는지)
- [트러블슈팅](#트러블슈팅)
- [부트스트랩 끝난 뒤](#부트스트랩-끝난-뒤)
- [License](#license)

## 언제 쓰나

Proxmox VE 에 PBS LXC 띄워두고 datastore 를 정기적으로 B2 에 rclone 해놓은 상태에서, 어느 날 호스트가 통째로 날라가는 시나리오. 디스크 고장이든 ransomware 든 실수든 — 어쨌든 베어메탈부터 다시 시작해야 하는 상황. 남아있는 건:

- B2 chunks bucket (datastore 통째로)
- B2 meta bucket (config + ssh keys, ansible 이 평소 채워둠)
- 외부 vault 에 적어둔 B2 application key 4개

이게 다 있으면 `bootstrap.sh` 한 줄로 PVE 베어메탈 → PVE GUI 에서 PBS 백업 browse / restore 가능한 상태까지 끌어다 줌. 그 다음 백업으로 뭐 할지 (어느 VM 부터 복원, 일정 등) 는 운영자 몫, 이 스크립트 범위 밖.

이런 경우엔 쓰지 마:

- PBS LXC 멀쩡한데 호스트만 갈아끼우려는 거면 → 평소 쓰던 terraform / ansible 로.
- B2 미러가 없으면 → 되살릴 데이터가 없음.
- 야간 PBS → B2 sync 자동화 → 그건 부트스트랩이 아니라 cron 으로 따로.

## bootstrap.sh 가 하는 일

1. PVE 호스트 apt repo 정리 (`pve-enterprise` → `pve-no-subscription`) + 필요한 패키지 설치 (`rclone`, `yq`, `iptables`, `ifupdown2`).
2. 호스트에 rclone B2 remote 설정 + meta bucket 의 `bootstrap-config.yml` 가져옴.
3. config 의 `host.bridges[*]` (보통 vmbr1) 를 `/etc/network/interfaces.d/` 에 드롭인으로 깔고 reload.
4. meta bucket 의 `authorized_keys` 받아서 호스트 `/root/.ssh/` 에 박고, 새 LXC seed 키로도 쓸 수 있게 임시 파일에 stage.
5. 호스트에 iptables MASQUERADE 임시 룰 — LAN firewall 죽어있어도 새 LXC 가 인터넷 도달하게.
6. unprivileged Debian 12 LXC 생성. CPU / 메모리 / 디스크 크기는 config 의 `pbs.*` 그대로.
7. LXC 안에 `proxmox-backup-server` 설치 (no-subscription repo, 신형 keyring 경로).
8. chunks bucket → datastore 경로로 `rclone copy` (foreground, 진행률 표시), 끝나면 `backup:backup` 으로 chown.
9. PBS 에 datastore 등록 (`/etc/proxmox-backup/datastore.cfg` 작성 + proxy reload).
10. PBS API user + token + `DatastoreAdmin` ACL 생성.
11. PVE 의 `/etc/pve/storage.cfg` 에 pbs storage entry 추가 (방금 만든 token + PBS TLS fingerprint 로).
12. LXC 네트워크를 declared steady-state gateway 로 원복 + 호스트 masquerade 룰 해제.

**여기까지 성공하면** PVE GUI 의 `pbs` storage 에 백업 그룹들이 보이면서 클릭 → restore 가능 상태.

## 전제조건

스크립트 돌리려면:

- **PVE 호스트** — 방금 베어메탈 설치 끝낸 상태. 설치 ceremony 에서 vmbr0 가 공유기 통해 인터넷 도달하게 IP 박아놨어야.
- **PVE GUI 접근** (`https://<vmbr0-ip>:8006`). 노트북에서 SSH 키 안 박혀있어도 됨 — 스크립트가 B2 mirror 에서 운영자 키 꺼내서 호스트랑 LXC 양쪽에 박아줌.
- **B2 키 4개** — 홈랩 밖에 보관해둔 거:
  - `B2_PBS_META_KEY_ID` / `B2_PBS_META_KEY` — meta bucket read
  - `B2_PBS_KEY_ID` / `B2_PBS_KEY` — chunks bucket read
- **B2 bucket 안에 미리 올려둔 것들** ([최초 셋업](#최초-셋업) 참고):
  - meta bucket 의 `bootstrap-config.yml`
  - meta bucket 의 `authorized_keys` (선택, 없으면 `PBS_SSH_PUBKEY_FILE` 로 fallback)
- **호스트 인터넷이 LAN firewall 와 독립**. 호스트의 default route 가 공유기 / ISP 모뎀이지 죽은 pfSense 가 아니어야 함. 부트스트랩 시작 전에 호스트에서 `curl -I https://api.backblazeb2.com` 으로 확인.

## 최초 셋업

재난 닥치기 전에 한 번만 해두면, 그 뒤로는 평소 자동화가 meta bucket 을 최신 상태로 유지.

### 1. B2 bucket 두 개 만들기

Backblaze B2 콘솔에서:

- **chunks bucket** (예: `my-pbs-chunks`) — PBS datastore 통째로 들어갈 큰 bucket.
- **meta bucket** (예: `my-pbs-meta`) — `bootstrap-config.yml` + `authorized_keys` 만 들어갈 작은 bucket.

타입은 Private. lifecycle / 암호화 / region 은 본인 정책대로.

### 2. Narrow-scope application key 발급

각 bucket 마다 한 쌍씩 총 두 쌍. B2 콘솔 → **Application Keys** → **Add a New Application Key**:

| 용도 | 범위 | 부트스트랩이 요구하는 권한 | Steady-state 에 추가로 필요한 권한 |
|---|---|---|---|
| `PBS_KEY` | chunks bucket only | `listBuckets`, `listFiles`, `readFiles` | `writeFiles`, `deleteFiles` (야간 sync 용) |
| `PBS_META_KEY` | meta bucket only | `listBuckets`, `listFiles`, `readFiles` | `writeFiles` (ansible 이 config / authorized_keys 갱신) |

**4개 값을 반드시 홈랩 밖에 보관해둘 것**. password manager, 암호화 USB, 종이 백업 등. 실제 DR 에선 Infisical / Vaultwarden / 뭐든 다 같이 죽어있음. 이 4개만은 외부에서 꺼낼 수 있어야 시작 가능.

### 3. `bootstrap-config.yml` 만들기

스크립트가 읽는 포맷:

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

# vmbr0 빼고 호스트가 추가로 필요한 bridge 들.
# 각 항목이 /etc/network/interfaces.d/<name>.conf 파일로 떨어짐.
# 비어있으면 이 단계 건너뜀.
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

각 섹션:

- `pbs.*` — PBS LXC 의 terraform 정의 그대로. 부트스트랩 끝나면 LXC 가 이 값들이랑 일치.
- `host.bridges[*]` — 호스트에 추가로 만들 bridge. vmbr0 는 PVE 설치 ceremony 가 이미 만들었으니 여기 넣지 마.
- `b2.*` — bucket 이름. rclone remote 이름으로도 그대로 씀.

우리 홈랩에선 이 파일이 ansible role 이 매 apply 마다 렌더해서 B2 에 올려놓음. 그래서 부트스트랩 돌릴 때 항상 최신 상태가 자동으로 잡힘.

### 4. meta bucket 에 올리기

```bash
# 로컬에 rclone 없으면 설치
brew install rclone   # macOS
# 또는: apt install -y rclone

# B2 remote 설정 (META 키로)
rclone config create meta b2 \
  account=<META_KEY_ID> \
  key=<META_APP_KEY>

# config 업로드
rclone copyto bootstrap-config.yml meta:my-pbs-meta/bootstrap-config.yml

# (선택) authorized_keys seed — 한 줄에 한 키
cat ~/.ssh/operator.pub | rclone rcat meta:my-pbs-meta/authorized_keys
```

`authorized_keys` 안 올려도 부트스트랩은 돎. 다만 그땐 실행 시점에 `PBS_SSH_PUBKEY_FILE` 로 로컬 키 파일 경로 알려줘야 함.

### 5. 확인

```bash
rclone cat meta:my-pbs-meta/bootstrap-config.yml
rclone cat meta:my-pbs-meta/authorized_keys
```

각각 내용 잘 나오면 DR 준비 끝. 진짜 재난 닥치기 전엔 부트스트랩 돌리지 마.

## DR 절차

**실제 재난 시점**에 할 일.

### 1. PVE 베어메탈 설치

PVE 설치 마법사 그대로:

- 디스크 선택. rootfs 는 `pbs.rootfs_size + 30 GB` 이상 잡기.
- Hostname: steady-state 이름 그대로 (예: `knowsu`).
- **vmbr0 IP / gateway / DNS** — 반드시 **공유기 (예: `192.168.0.1`)** 가리키게. 복구 대상인 LAN firewall VM 은 죽어있으니 그쪽 가리키면 안 됨.
- root 비밀번호 설정.

### 2. PVE 웹쉘 열기

브라우저로 `https://<vmbr0-ip>:8006` → `root@pam` 로그인 → 노드 클릭 → **Shell** 탭.

이후 명령 다 이 탭 안에서. 페이지 이동해도 세션 살아있고 SSH 키 미리 안 박혀있어도 OK.

### 3. B2 키 export

외부 password manager 에서 4개 꺼내 붙여넣기:

```bash
export B2_PBS_META_KEY_ID='<meta-key-id>'
export B2_PBS_META_KEY='<meta-app-key>'
export B2_PBS_KEY_ID='<chunks-key-id>'
export B2_PBS_KEY='<chunks-app-key>'
```

파일로 저장하지 마. 부트스트랩 끝난 뒤 쉘 그대로 쓸 거면 `unset` 으로 지우기.

### 4. 호스트 인터넷 확인

```bash
curl -I https://api.backblazeb2.com
```

`200` 또는 `301` 나오면 OK. 실패하면 호스트 업스트림부터 고치고 와 — 이 단계 못 넘기면 부트스트랩이 뭘 해도 안 됨.

### 5. 부트스트랩 실행

```bash
curl -sSL https://raw.githubusercontent.com/bigpie1367/pbs-bootstrap/main/bootstrap.sh | bash
```

또는 한 번 훑어보고 돌리려면 clone 부터:

```bash
apt install -y git
git clone https://github.com/bigpie1367/pbs-bootstrap /tmp/pbs-bootstrap
/tmp/pbs-bootstrap/bootstrap.sh
```

각 단계마다 `== name ==` 헤더 찍힘. 가장 오래 걸리는 건 chunks restore — bucket 크기 / egress 속도에 따라 수십 분에서 몇 시간.

### 6. 잘 됐는지 확인

웹쉘에서:

```bash
pct status <vmid>                                               # → status: running
pct exec <vmid> -- proxmox-backup-manager datastore list        # → datastore 이름 보임
pvesm status -storage pbs                                       # → active
```

PVE GUI: `Datacenter → Storage → pbs` 클릭 → backup browser 에 백업 그룹들 보이면 끝.

여기까지 왔으면 부트스트랩 임무 완료. 그 다음은 [부트스트랩 끝난 뒤](#부트스트랩-끝난-뒤) 참고.

## 환경변수

기본값은 스크립트 안에 `: "${VAR:=default}"` 로 박혀있음. 실행 전에 export 로 override.

거의 안 만질 거고, 만질 만한 건:

- `PBS_META_BUCKET` — 본인 bucket 이름이 `siroh-pbs-meta` (작성자 기본값) 가 아니면.
- `PBS_REPO_URL` — repo fork 했을 때.
- `PBS_SSH_PUBKEY_FILE` — B2 mirror 가 아직 없는 첫 부트스트랩 때 로컬 키 파일 경로 가리키기.

| 변수                    | 기본값                                        | 역할                                                      |
|-------------------------|-----------------------------------------------|-----------------------------------------------------------|
| `PBS_TEMPLATE`          | `debian-12-standard_12.7-1_amd64.tar.zst`     | LXC 템플릿 (`pveam` 으로 받을 수 있는 이름).                |
| `PBS_TEMPLATE_STORAGE`  | `local`                                       | 템플릿 보관 storage.                                       |
| `PBS_IP_CIDR`           | `24`                                          | config 의 bare IP 에 붙일 CIDR.                            |
| `PBS_SSH_PUBKEY_FILE`   | _없음_                                        | B2 미러 비어있을 때 fallback 으로 쓸 로컬 키 파일 경로.      |
| `PBS_META_BUCKET`       | `siroh-pbs-meta`                              | `bootstrap-config.yml` + `authorized_keys` 들어있는 bucket. |
| `PBS_CONFIG_OBJECT`     | `bootstrap-config.yml`                        | meta bucket 안 config 파일 이름.                            |
| `PBS_AUTH_KEYS_OBJECT`  | `authorized_keys`                             | meta bucket 안 SSH 키 미러 파일 이름.                        |
| `PBS_NAT_OUT_IFACE`     | `vmbr0`                                       | MASQUERADE 의 out-iface (호스트 업스트림 쪽).                |
| `PBS_NAT_DNS`           | `1.1.1.1`                                     | LXC 에 임시 박을 DNS resolver.                              |
| `PBS_GATEWAY_OVERRIDE`  | _PBS_BRIDGE 의 호스트 IP 자동감지_            | 부트스트랩 동안 LXC gateway 수동 override.                  |
| `PBS_DNS_OVERRIDE`      | _PBS_NAT_DNS 와 동일_                          | 부트스트랩 동안 LXC DNS 수동 override.                      |
| `PBS_GC_SCHEDULE`       | `4:00`                                        | 새로 등록되는 datastore 의 GC schedule.                     |
| `PBS_NOTIFICATION_MODE` | `notification-system`                         | Datastore 알림 라우팅 모드.                                 |
| `PBS_PVE_USER`          | `pve`                                         | PVE 가 PBS 에 인증할 때 쓸 user (`<user>@pbs`).             |
| `PBS_PVE_TOKEN_NAME`    | `pve-backup`                                  | PBS API token 이름 (`<user>@pbs!<token>`).                  |
| `PBS_PVE_ROLE`          | `DatastoreAdmin`                              | user + token 에 부여할 ACL role.                            |
| `PBS_PVE_STORAGE_ID`    | `pbs`                                         | `/etc/pve/storage.cfg` 의 storage 이름.                      |

cores / memory / rootfs 크기는 환경변수가 **아님**. `bootstrap-config.yml` 에서 옴 — steady-state terraform 정의랑 무조건 일치하게 만들어둠.

## 네트워크 shim 이 뭐 하는지

부트스트랩은 DR 도구라 LAN gateway 가 살아있다고 가정 안 함. 매번:

1. 호스트에 `sysctl net.ipv4.ip_forward=1` 켜기 (이전 값은 저장).
2. `iptables -t nat -A POSTROUTING -s <lan-subnet> -o $PBS_NAT_OUT_IFACE -j MASQUERADE` 추가.
3. LXC 만들 때 `--nameserver $PBS_NAT_DNS` + `gw=<호스트 bridge IP>` 로 — LAN firewall 죽어있어도 chunks restore 가 B2 도달.
4. Chunks 다 받고 datastore 등록 끝나면 `pct set --net0` 으로 declared steady-state gateway 로 되돌림.
5. 스크립트 종료될 때 (성공/실패 무관) iptables 룰 빼고 `ip_forward` 원래대로.

shim 은 부트스트랩 동안 **항상 켜져있고**, 끝나면 **항상 정리됨**. 토글 안 함.

## 트러블슈팅

### Chunks restore 가 너무 느려

- B2 의 class B (download) 트랜잭션 / 대역폭 한도일 가능성. Backblaze dashboard 에서 확인.
- `lib/chunks-restore.sh` 의 `--transfers 16 --checkers 32` 는 일반 가정용 회선 기준으로 잡힌 값. 대역폭 더 있으면 올리고 재시도.

### 부트스트랩 중에 LXC 가 네트워크 못 잡음

```bash
pct exec <vmid> -- ip -4 addr show
pct exec <vmid> -- ip -4 route show
pct exec <vmid> -- cat /etc/resolv.conf
```

흔한 원인:

- bridge 이름 안 맞음 — config 엔 `vmbr1` 인데 호스트에 그게 없음. `ip link show vmbr1` 로 확인.
- MASQUERADE 룰 빠짐 또는 out-iface 잘못. `iptables -t nat -L POSTROUTING -n` 으로 확인.
- DNS 안 잡힘 — `/etc/resolv.conf` 비어있음. shim 이 `1.1.1.1` 박는데 `PBS_NAT_DNS` 를 호스트에서 도달 못하는 값으로 바꿔놨을 수도.

### LXC 안에서 `apt update` 실패

Debian 12 LXC 의 IPv6 default route 가 자주 망가져있음. 스크립트가 `/etc/apt/apt.conf.d/99force-ipv4` 로 IPv4 강제. 그래도 실패하면:

```bash
pct exec <vmid> -- bash -c "curl -4 -I https://deb.debian.org"
```

이것도 실패 → LXC egress 자체가 문제. 위의 "네트워크 못 잡음" 절로.

### 부트스트랩 끝났는데 datastore 가 안 보여

```bash
pct exec <vmid> -- journalctl -u proxmox-backup-proxy --no-pager -n 50
pct exec <vmid> -- ls -la /etc/proxmox-backup/
pct exec <vmid> -- ls -la <datastore-path> | head
```

흔한 원인:

- `datastore.cfg` 의 소유 잘못 — `root:backup` mode `0640` 이어야.
- datastore 경로 안 chunks 가 아직 `root` 소유 그대로 — `pct exec <vmid> -- chown -R backup:backup <datastore-path>` 다시.

### PVE GUI 에는 백업 보이는데 `pvesm list pbs` 가 비어있어

PBS API 쪽 ACL / ownership 문제. 정상이라면 `pbs_auth_setup` 이 `<user>@pbs` 랑 `<user>@pbs!<token>` 양쪽에 `DatastoreAdmin` 박았을 것. 중간에 실패했으면 직접:

```bash
pct exec <vmid> -- proxmox-backup-manager acl update \
    /datastore/<name> DatastoreAdmin --auth-id <user>@pbs
pct exec <vmid> -- proxmox-backup-manager acl update \
    /datastore/<name> DatastoreAdmin --auth-id '<user>@pbs!<token>'
```

### `pveam download` 가 템플릿 못 찾아

기본값 `debian-12-standard_12.7-1_amd64.tar.zst` 가 Proxmox 미러에서 더 새 minor 로 대체됐을 수 있음. 현재 이름 확인:

```bash
pveam update
pveam available --section system | grep debian-12-standard
```

찾은 이름으로 `PBS_TEMPLATE=<새-이름> bash ./bootstrap.sh` 재실행.

### LXC 이미 존재한다고 거부

부트스트랩은 one-shot 이라 같은 VMID 덮어쓰기 안 함. 직전 run 이 중간에 죽었으면:

```bash
pct stop <vmid> --force 2>/dev/null
pct destroy <vmid> --force
```

그 다음 다시 실행. 중간 상태에서 이어 가는 resume 모드는 없음.

## 부트스트랩 끝난 뒤

PVE 가 PBS 보는 시점에서 스크립트는 일부러 멈춤. 그 뒤는 운영자 영역:

- PBS GUI 에 직접 로그인하고 싶으면 root 비밀번호 박기 — `pct exec <vmid> -- passwd root`.
- PVE GUI 에서 VM / CT 복원 — 본인 순서대로. "다 잃은" DR 이라면 보통 LAN firewall VM 먼저 (네트워크 살리고) → 인프라 (secret manager, 모니터링) → 앱 게스트들 순서.
- Steady-state 자동화 재시동 — 야간 chunks sync, prune / verify / GC, 알림, 모니터링 등. 평소 ansible / terraform / cron 이 하던 거 다시 돌리면 됨.

이 분리가 의도적인 이유: 우리 홈랩이랑 매우 다른 셋업에서도 부트스트랩이 그대로 쓸모있으려면, 복원 정책이나 일상 운영 같은 사용자 특화 영역은 각자 repo 에 두는 게 맞아.

## License

MIT — [LICENSE](LICENSE) 참고.

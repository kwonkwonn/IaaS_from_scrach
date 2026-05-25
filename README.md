# IaaS_from_scrach

단일 Linux 호스트에서 KVM/QEMU, MicroCeph(RBD), network namespace, veth, bridge, TAP을 이용해 3개의 Ubuntu VM을 구성하는 실습용 IaaS 랩입니다.

VM 구성은 다음과 같습니다.

- `vm1`, `vm2`는 같은 L2 세그먼트(`vnet-a`)에 위치
- `vm3`는 별도 L2 세그먼트(`vnet-b`)에 위치
- 각 VM은 Ceph RBD 디스크에서 부팅
- 호스트에서 SSH 포워딩, VNC 접속, QoS 벤치마크, 스냅샷 관리까지 가능

## 구조

| 파일 | 역할 |
|---|---|
| `00_prereq.sh` | 패키지 설치, `/dev/kvm` 검사, MicroCeph bootstrap, loop OSD 생성, 런타임 디렉터리 준비 |
| `01_microceph.sh` | RBD 이미지 생성, Ubuntu cloud image를 각 디스크에 기록 |
| `02_network.sh` | network namespace, veth, bridge, TAP, NAT, SSH DNAT 구성 |
| `03_vm.sh` | cloud-init seed 생성, QEMU VM 실행, QoS 옵션 적용 |
| `04_test.sh` | 네트워크/SSH/ping/QoS 벤치마크 검증 |
| `05_snapshot.sh` | RBD snapshot 생성, 조회, 롤백, purge |
| `cleanup.sh` | VM 종료, 네트워크 정리, RBD/pool 정리, 임시 파일 삭제 |

## 토폴로지

```text
Host
├── veth-a-host (10.0.0.1/30) ─── veth-a-ns (10.0.0.2/30) [namespace: vnet-a]
│                                     └── br-vnet-a (192.168.0.254/24)
│                                             ├── tap-vm1 → vm1 (192.168.0.1)
│                                             └── tap-vm2 → vm2 (192.168.0.2)
│
└── veth-b-host (10.0.1.1/30) ─── veth-b-ns (10.0.1.2/30) [namespace: vnet-b]
				      └── br-vnet-b (192.168.0.254/24)
					      └── tap-vm3 → vm3 (192.168.0.3)
```

- `vm1` ↔ `vm2` 는 서로 ping 가능
- `vm3` 는 분리된 namespace에 있어 `vm1`, `vm2` 와 L2 레벨에서 분리됨

## 요구사항

- Linux 호스트
- root 권한
- `/dev/kvm` 사용 가능
- CPU virtualization flag `vmx` 또는 `svm`
- nested virtualization이 필요한 환경에서는 host 쪽에서 허용되어 있어야 함

`00_prereq.sh` 는 다음 패키지를 설치합니다.

- `qemu-system-x86`
- `qemu-utils`
- `ceph-common`
- `iproute2`
- `iptables`
- `cloud-image-utils`
- `numactl`
- `ovmf`
- `wget`
- `sshpass`

## 빠른 시작

전체 구성은 Makefile 기준으로 아래 순서로 실행합니다.

```bash
sudo make all
```

개별 단계만 실행할 수도 있습니다.

```bash
sudo make prereq
sudo make microceph
sudo make network
sudo make vms
```

테스트는 다음과 같이 실행합니다.

```bash
sudo make test
```

주의: `04_test.sh` 를 직접 실행하면 Makefile의 환경변수를 자동으로 받지 못해서 `VM_QOS_BENCH` 가 기본값 0으로 처리됩니다. 그래서 QoS benchmark까지 포함하려면 `sudo make test` 를 쓰는 편이 맞습니다.

## 접속 방법

VM은 호스트에서 직접 IP로도, 포트 포워딩으로도 접속할 수 있습니다.

직접 IP:

```bash
ssh ubuntu@192.168.0.1
ssh ubuntu@192.168.0.2
ssh ubuntu@192.168.0.3
```


VNC는 다음 포트를 사용합니다.

- `vm1`: `127.0.0.1:5901`
- `vm2`: `127.0.0.1:5902`
- `vm3`: `127.0.0.1:5903`

로그는 아래 경로에 쌓입니다.

- serial console: `/var/log/vms/<vm>-console.log`
- QoS benchmark: `/var/log/qos_bench.log`

## QoS 벤치마크

`03_vm.sh` 는 `VM_QOS_BENCH=1` 일 때 cloud-init으로 벤치마크 스크립트를 VM 내부에 주입합니다. 첫 부팅 시 `dd` 를 이용해 write/read 테스트를 수행하고 결과를 `/var/log/qos_bench.log` 에 남깁니다.

관련 설정은 Makefile 상단에서 조정합니다.

- `VM_QOS_BENCH`
- `QOS_BENCH_LOG`
- `QOS_BENCH_BS`
- `QOS_BENCH_COUNT`
- `VM_QOS_IOPS_LIMIT`
- `VM_QOS_BPS_LIMIT`
- `VM_QOS_READ_IOPS_LIMIT`
- `VM_QOS_WRITE_IOPS_LIMIT`
- `VM_QOS_READ_BPS_LIMIT`
- `VM_QOS_WRITE_BPS_LIMIT`
- `VM_QOS_IOPS_BURST`
- `VM_QOS_BPS_BURST`

QoS 제한은 QEMU block throttling 파라미터로 적용됩니다. 값이 `0` 이면 제한 없음입니다.

## CPU pinning

Makefile에는 CPU pinning 옵션도 있습니다.

- `VM_CPU_PIN=1` 이면 `taskset -c` 로 VM별 CPU set을 적용
- `VM1_CPUSET`, `VM2_CPUSET`, `VM3_CPUSET` 에 범위 또는 리스트를 지정

예:

```bash
VM_CPU_PIN=1 VM1_CPUSET=1-2 VM2_CPUSET=3-4 VM3_CPUSET=5-6 sudo make vms
```

## UEFI

- `VM_UEFI=0` 이면 legacy BIOS
- `VM_UEFI=1` 이면 OVMF 기반 UEFI 부팅

관련 파일:

- `OVMF_CODE`: `/usr/share/OVMF/OVMF_CODE_4M.fd`
- `OVMF_VARS`: `/usr/share/OVMF/OVMF_VARS_4M.fd`

## Snapshot

`05_snapshot.sh` 는 RBD snapshot을 관리합니다.

```bash
sudo bash 05_snapshot.sh create all
sudo bash 05_snapshot.sh list all
sudo bash 05_snapshot.sh rollback vm1 snap-YYYYMMDD-HHMMSS
sudo bash 05_snapshot.sh purge all
```

Makefile 안의 snapshot target 은 현재 주석 처리되어 있으므로, 필요하면 직접 스크립트를 호출하세요.

## 정리

전체 환경 제거는 다음 명령으로 합니다.

```bash
sudo make clean
```

이 작업은 VM 종료, namespace 삭제, NAT/route 제거, RBD 이미지 삭제, 임시 디렉터리 정리를 수행합니다.

## 문제 해결

- `sudo ./04_test.sh` 를 직접 실행했을 때 QoS benchmark가 스킵되면, Makefile의 환경변수가 전달되지 않은 것입니다. `sudo make test` 를 사용하세요.
- `/dev/kvm` 오류가 나면 nested virtualization 또는 VT-x/AMD-V 지원을 확인하세요.
- `sshpass not found` 메시지가 보이면 VM-level ping 검사가 일부 건너뛰어질 수 있습니다.
- `make clean` 후에도 네트워크가 남아 보이면 `ip netns list`, `ip link`, `iptables -t nat -S` 로 잔여 상태를 확인하세요.

## 설정값

실제 동작 값은 Makefile에서 관리합니다. 대표 항목은 다음과 같습니다.

- Ceph pool: `vms`
- VM RAM: `2048 MB`
- VM CPU: `1`
- VM IP: `192.168.0.1`, `192.168.0.2`, `192.168.0.3`
- VM gateway: `192.168.0.254`
- VM SSH 포트: `2201`, `2202`, `2203`
- VM VNC 포트: `5901`, `5902`, `5903`

필요하면 Makefile 상단의 변수만 수정하면 전체 스크립트가 그 값을 따라갑니다.

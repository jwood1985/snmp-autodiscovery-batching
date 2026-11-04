# Cloud SNMP Autodiscovery Test Bed — Implementation Plan

**Goal:** Stand up a self-contained, cloud-hosted test bed to validate and scale Dynatrace SNMP
autodiscovery (toward /16 → /8 coverage) against *real* SNMP devices **and** large simulated ranges —
without depending on home-LAN gear. Doing this in-cloud sidesteps every blocker this project hit on
physical hardware (LAN routing, ARM ActiveGates, stale AG versions, firewall/community mismatches).

## Why cloud (what it fixes)
- **Reachability:** a cloud ActiveGate shares the VNet/VPC with the targets, so there is no
  home-LAN routing problem (the cloud VM AG could never reach `192.168.1.0/24`).
- **ActiveGate fitness:** we control the AG image — guaranteed **x86-64, current version, EEC enabled**
  (the Pi was arm64 and couldn't run the Python datasource; the Dell AG was a 2022 build the cluster
  rejected; the EdgeSmart path depended on fragile home wiring).
- **Deterministic scope:** the AG lives in a dedicated AG group, so config assignment is predictable.

---

## Architecture

```
            ┌────────────────────────── Cloud VNet / VPC (e.g. 10.20.0.0/16) ──────────────────────────┐
            │                                                                                            │
  Dynatrace │   ActiveGate VM (x86-64, current, EEC)        Real NVAs                 SNMP Simulator VM  │
  cluster <─┼── group: ag_group-cloud-snmp  ──poll 161──►   - Cisco Catalyst 8000V    snmpsim, 1 VM     │
  (qof78400)│        │                                      - FortiGate-VM            emulating 1000s of │
            │        └──────── autodiscovery configs ──────►- (opt) Arista vEOS       virtual devices on │
            │                                                 SNMP v2c "public-wood"   distinct IPs       │
            └────────────────────────────────────────────────────────────────────────────────────────┘
```

Two target tiers:
1. **Fidelity** — a few real **NVAs** (genuine SNMP agents: real sysObjectID, ifTable, vendor MIBs) to
   validate discovery *and* the downstream `snmp-generic-device` / vendor extensions.
2. **Scale** — one **SNMP simulator** VM emulating hundreds–thousands of devices on distinct IPs to
   stress batching, the `.252` enumeration, cadence, and per-AG throughput — cheaply.

---

## Components & build steps

### A. Network (AWS or Azure — pick one)
- One VNet/VPC, e.g. `10.20.0.0/16`, one subnet for the AG + targets.
- **Security group / NSG:** allow **UDP 161** from the AG's IP to the target subnet (and UDP 162 if you
  also want traps). Keep it intra-VNet; no public exposure of SNMP.
- Decide a target addressing scheme that mirrors prod so the batching logic transfers. To exercise the
  **`.252` enumeration** directly, give simulated devices addresses like `10.<b>.<c>.252`.

### B. ActiveGate VM (the lesson-hardened part)
- **x86-64**, current ActiveGate version (≥ the cluster's; avoid the 2022-build rejection we saw).
- Enable the **Extension Execution Controller** capability (the Python datasource must run).
- Put it in a **dedicated AG group** (e.g. `cloud-snmp`) so autodiscovery configs deploy *only* here.
- Do **not** co-locate conflicting roles; keep it a clean extensions AG.
- Verify from the AG host: `snmpget -v2c -c public-wood <target> 1.3.6.1.2.1.1.1.0` returns sysDescr
  before touching Dynatrace.

### C. Real NVAs (fidelity)
- Deploy from AWS/Azure Marketplace (BYOL or hourly):
  - **Cisco Catalyst 8000V** (IOS-XE) — `snmp-server community public-wood RO`
  - **Fortinet FortiGate-VM** (FortiOS) — SNMP v2c community `public-wood`, RO
  - *(optional)* **Arista vEOS / Juniper vSRX** for more sysObjectID variety.
- Enable SNMP v2c RO with community `public-wood`; confirm each answers GET on 161 from the AG.
- *(Alternative to self-managing VMs: **Equinix Network Edge** or **Megaport Virtual Edge** provision the
  same vendor devices as NaaS with CLI/SNMP you manage.)*

### D. SNMP simulator (scale)
- One VM running **snmpsim** (or the Dynatrace device simulator — same approach as the existing
  `Simulator` config on `10.1.0.x`).
- Bind many virtual agents to distinct IPs/ports to emulate hundreds–thousands of devices.
- Load a realistic recording (sysDescr/sysObjectID/ifTable) so discovery classifies them.
- Address them to match the batching test (e.g. a block of `10.<b>.<c>.252`).

### E. Dynatrace autodiscovery configs
> ⚠️ **Superseded by field results — see "Measured Results & Corrections" at the end.**
> On current ActiveGates (Python 3.14 runtime) use **extension 4.3.4** with a **platform token**
> (`dt0s…`, scopes `storage:buckets:read` + `storage:smartscape:read`) and `scanner.profile`.
> The 2.4.7 / `entities.read` / `threads` guidance below applies only to older AGs and is kept for history.
- **Extension version: 2.4.7** (the 3.0.0 `utils.py:177 getOid()` bug crashes on any responding device;
  see `docs/dynatrace-snmp-auto-discovery-3.0.0-bug.md`). Scanner uses `threads` (not `profile`).
- **De-dup token:** API token with `entities.read`, set in each config's `scanner.token`.
- **Community:** `public-wood`, SNMP v2c, port 161.
- **Packing:** ≤100 configs/extension; ≤100 groups/config; ≤100 addresses/group (≤10,000 entries/config).
- **Cadence:** 5 min for canaries during bring-up; 720 min for the full sweep.
- **Batching modes to exercise:**
  - Contiguous: a `/16`-equivalent block of simulated devices in one config.
  - **`.252` enumeration:** `10.*.*.252` = 65,536 `/32` entries → 7 configs (the 256× reduction that makes
    /8-scale coverage feasible on a single AG, ~4.6 h/sweep isolated).

---

## Validation & success criteria
1. **Reachability:** `snmpget` from the AG to one NVA and one simulated IP succeeds.
2. **Discovery:** config status `OK`; `sfm.snmp_autodiscovery.devices_ok ≥ 1`; `network:device` entities
   appear with correct `sys.object.id` / `sys.descr`.
3. **No crash:** zero `getOid` errors in `…\datasources\python*.log` (confirms 2.4.7 path).
4. **Throughput recalibration:** record `scan_duration` vs. address count on the cloud AG — redo the
   per-IP-rate math here (home AG measured ~0.25 s/IP, ~3.2 under contention). Cloud AG + a **dedicated
   EEC performance profile** likely scans faster → fewer AGs for /8.
5. **Scale extrapolation:** from the simulator run, recompute AGs needed for /8 at daily / weekly cadence.

## OID / target usage assessment (no disk-risky AG-wide debug)
- Target usage: `sfm.snmp_autodiscovery.devices_scanned / devices_ok / scan_duration` per config.
- OID usage: discovery records already expose the probe set (system group — sysDescr/sysObjectID/
  sysName/sysContact/sysLocation). For wire-level detail use **`tcpdump -ni any udp port 161`** on the AG
  against a bounded canary, not EEC debug (which is AG-wide and high-volume).

## Cost notes
- NVAs: vendor license + VM/hr (can be significant) — keep to 1–3 for fidelity.
- Simulator: 1 small VM covers thousands of devices — the cheap path for scale.
- ActiveGate: 1 VM. Prefer a **dedicated EEC performance profile** to raise scan throughput.

## Open decisions (RESOLVED — see "Decisions (locked)" below)
1. **Cloud:** AWS or Azure? (Existing cloud footprint is Azure — `*.cloudapp.net` AGs.)
2. **NVA mix:** Catalyst 8000V only, or add FortiGate/Arista for sysObjectID variety?
3. **Self-managed NVAs vs. Equinix/Megaport NaaS?**
4. **Simulated scale:** how many virtual devices / which address block to mirror prod?
5. **Who provisions cloud resources** — this session has no AWS/Azure credentials; provisioning is
   done by you (or a pipeline). This plan + the Dynatrace-side configs are what this project automates.

## Scope boundary
This session can build the **Dynatrace-side** automation (autodiscovery config generation, batching,
`.252` enumeration, dtctl apply, validation queries) against whatever targets exist. It **cannot**
provision AWS/Azure VNets/NVAs/VMs (no cloud credentials here) — that step is yours or a cloud pipeline's.

---

## Decisions (locked) & provisioning

- **Cloud:** Azure (matches existing `*.cloudapp.net` footprint).
- **NVAs:** Cisco Catalyst 8000V + Fortinet FortiGate-VM (self-managed Marketplace VMs).
- **Scale:** ~10,000 simulated devices via **snmpsim on one VM** that owns a routed `/18`
  (`ip route add local <cidr> dev lo` + NIC IP-forwarding + UDR). No per-IP Azure config.
- **Provisioner:** the user (this cloud session cannot reach `management.azure.com`).

**Automation:** `provisioning/azure-snmp-testbed.sh` — idempotent, `APPLY=1`-gated az-CLI build of
RG, VNet/subnet, NSG (SSH locked to your IP; intra-VNet UDP 161 via default rule), the ActiveGate VM,
the snmpsim VM (+ UDR + IP forwarding + cloud-init), and the two NVAs (Marketplace terms + create).
Run it where `az login` works; `APPLY=1 ./azure-snmp-testbed.sh teardown` removes everything.
NVA Marketplace URNs version frequently — discover and set `CISCO_URN` / `FORTI_URN` (commands in the script).

## Cost (approx, East US PAYG; deallocate when idle)
| Component | Running | Idle (deallocated) |
|---|---|---|
| Simulator VM (D8s_v5, ~10k devices) | ~$0.38/hr (~$280/mo) | ~$5/mo (disk) |
| ActiveGate VM (D2s_v5) | ~$0.10/hr (~$70/mo) | ~$3/mo |
| NVAs ×2 (Catalyst 8000V + FortiGate-VM), **BYOL** | **VM-only: ~$0.19/hr each (~$140/mo)** — no vendor hourly fee | ~$5/mo each |
| Private IPs / intra-VNet traffic | $0 | $0 |

**Per short test window (all deallocated between runs): single-digit dollars.** The NVAs dominate cost;
the 10k-device simulator is effectively one cheap VM.

## NVA licensing (BYOL)
The Azure Marketplace Catalyst 8000V images are **BYOL** — no Cisco hourly software fee; you bring a
license or run **unlicensed/eval**. For this test bed that's fine: Cisco licensing throttles **data-plane
throughput/features, not the SNMP management plane**, so an unlicensed/eval C8000V still answers
GETs (sysDescr/sysObjectID/ifTable) — exactly what discovery needs. Net effect: NVA cost ≈ VM compute only.

**Zero-license alternative for fidelity:** load real vendor **`.snmprec` recordings** (a Cisco walk, a
FortiGate walk) into snmpsim and map them to specific IPs. Autodiscovery keys on `sysObjectID`, so a
recording classifies identically (correct `recommended.extension`). Real NVAs are only needed to later
exercise the live vendor *monitoring* extensions against dynamic tables.

---

## Measured Results & Corrections (qof78400, Azure, Nov 2026)

Built and measured end to end on the live test bed. **Where this section conflicts with the plan above,
this section wins** — it reflects what actually worked on a current ActiveGate.

### As-built environment
- **ActiveGate** `vm-ag.internal.cloudapp.net`, group `cloud-snmp`, Linux **x86-64**, AG **1.349**,
  EEC performance profile **HIGH**. Resized **D2s_v5 (2 vCPU) → D8s_v5 (8 vCPU)** mid-campaign.
- **Simulator** `vm-snmpsim`, **snmpsim-lextudio**, owns routed **`10.20.64.0/18`** (local route on `lo`
  + NIC IP-forwarding + UDR); community `public-wood`. ~16k addressable; 10k used per test config.
- **Unrouted** `10.20.128.0/18` (in-VNet, no subnet/route) used as the timeout (non-responder) target.

### Corrections to the plan (these cost real debugging time)
1. **Extension must be 4.3.4, not 2.4.7, on current AGs.** AG 1.349 ships a **Python 3.14** datasource
   runtime. 2.4.7 bundles `dt-extensions-sdk 1.2.14` pinned to **Python <3.11** → venv build fails,
   config stuck `ERROR` (`requires a different Python: 3.14.10 not in '<3.11,>=3.10'`). 3.0.0 builds but
   still has the `getOid` crash. **4.3.4** (`dt-extensions-sdk 1.11.2`, `pysnmp 7.x`) builds on 3.14 **and**
   has the `getOid` fix.
2. **Install from the Hub via API when the UI balks.** The Hub UI on this INTERNAL tenant would not
   upgrade past 2.4.7. Install worked via:
   `dtctl create extension --hub-extension com.dynatrace.extension.snmp-auto-discovery --version 4.3.4`.
3. **Token: platform token, not classic.** 4.x on **SaaS** requires a **platform token** (`dt0s…`) with
   **`storage:buckets:read` + `storage:smartscape:read`** in `scanner.token`. A classic `dt0c01`
   `entities.read` token → HTTP 401, fastcheck `WARNING`, and the scan **never promotes** past fastcheck
   (config shows `ERROR`/looping). This was the final gate before any scan ran.
4. **Scanner uses `profile`** (`DEFAULT` / `HIGH` / `DEDICATED`), not `threads` (that was 2.4.x).
5. **`frequency` must exceed `scan_duration`.** A `frequency: 5` (300 s) config whose scan takes 303 s
   throws `run_in_thread … took 302.99s, longer than the interval of 300.0s` every cycle. Production
   720-min cadence is nowhere near this; aggressive test cadences hit it.

### Throughput (10,000 `/32` targets per config; measured `sfm.snmp_autodiscovery.scan_duration`)
| AG size | `scanner.profile` | workload | devices_ok | **scan_duration** | per-IP | high-CPU event |
|---|---|---|---|---|---|---|
| D2s_v5 (2 vCPU) | DEFAULT | all-respond | 10,000 | ~200 s | 0.020 s | no |
| D2s_v5 (2 vCPU) | DEFAULT | timeout | 0 | 303 s | 0.030 s | **fired** |
| D8s_v5 (8 vCPU) | DEFAULT | timeout | 0 | 286 s | 0.029 s | none |
| D8s_v5 (8 vCPU) | **DEDICATED** | timeout | 0 | **85.6 s** | **0.0086 s** | fired once (transient) |

**Interpretation**
- **Empty-space sweeps are I/O-bound (SNMP timeout waits), not CPU-bound.** 2→8 vCPU barely changed time
  (303→286 s) but cleared CPU saturation. Cores buy *headroom*, not *speed*.
- **Concurrency is the speed lever.** `DEDICATED` profile (safe only once 8 vCPU gave headroom) cut the
  timeout scan **3.3×** to **85.6 s/10k ≈ 117 IP/s**. On 2 vCPU this would have worsened the CPU alert.
- All-respond (live devices) is *faster* per-IP than timeout; a real /8 is timeout-dominated, so the
  timeout rate governs sizing.

### /8 sizing (best setting: 8-vCPU AG, `DEDICATED`, ~117 IP/s timeout-bound)
| Target | addresses | 1-AG sweep | AGs @ 12 h cadence | AGs @ 24 h |
|---|---|---|---|---|
| **`.252` enumeration** (`10.*.*.252`) | 65,536 | **~9 min** | **1** | 1 |
| **Full /8** (every address) | 16,777,216 | ~40 h | ~4 \* | ~2 \* |

\* **Throughput only.** The **100 configs × 10k = 1,000,000 addresses per AG-group** limit means a full /8
(16.7 M) needs **≥17 AG-groups'-worth of configs regardless of speed**. → **The `.252` enumeration is the
recommended path:** 65,536 addresses = **7 configs in one group on one AG, ~9 min/sweep**, trivially within
any cadence. (Contended home-lab math implied **50–65 AGs** for /8; the dedicated 8-vCPU + DEDICATED cloud
AG is ~15× more capable per node, and `.252` collapses /8 to a single AG.)

### Open follow-ups
- **Topology entities:** `EXT_NETWORK_DEVICE` smartscape count stayed **0** despite `devices_ok = 10,000`
  and 20,001 metric lines ingested. Autodiscovery *inventories* devices and emits metrics; materializing
  `EXT_NETWORK_DEVICE` nodes likely needs the `snmp-generic-device` monitoring extension. Confirm for rollout.
- **Sustained load:** `DEDICATED` tripped the high-CPU detector once (transient) even on 8 vCPU; size the AG
  (or cap concurrency) for continuous multi-config operation.
- **Not yet measured:** all-respond at `DEDICATED`/8 vCPU (only timeout was swept there); profile `HIGH`
  as a middle point.

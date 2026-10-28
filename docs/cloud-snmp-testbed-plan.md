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

## Open decisions (need input before provisioning)
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

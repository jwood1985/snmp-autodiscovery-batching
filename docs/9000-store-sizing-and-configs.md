# 9,000-store rollout: load sizing, fixed-last-octet autodiscovery configs, heuristics

Target scale: **9,000+ stores**, **~90,000 ICMP tests**, **~20,000 SNMP devices**
(≈10 ICMP targets and ≈2.2 SNMP devices per store).

Evidence grade is marked throughout: **[M]** measured on this test bed, **[E]** extrapolated from a
measurement, **[U]** unmeasured / needs a pilot. Measurements come from
`docs/cloud-snmp-testbed-plan.md` and `docs/50k-topology-sizing.md`.

---

## 0. The single biggest caveat before any number below
All throughput numbers were measured **intra-VNet with sub-millisecond RTT and ~0 packet loss**.
A 9,000-store estimate is **WAN-bound**: 20–100 ms RTT, jitter, and loss → SNMP timeouts/retries
dominate, and per-AG capacity drops materially. SNMP sweeping is **I/O/latency-bound, not CPU-bound**
**[M]**, so WAN latency hits throughput roughly proportionally to RTT+retry time per target.
**Treat lab figures as an optimistic ceiling and calibrate against one real region first.** **[U]**

---

## 1. Can the ActiveGates handle it?

Three separate workloads — do not size them as one.

### 1a. SNMP autodiscovery (sweep/inventory) — **comfortable, not the problem** [M]
Measured with extension 4.3.4, 10,000 `/32` per config, `sfm.snmp_autodiscovery.scan_duration`:

| AG | profile | workload | scan_duration | per-IP |
|---|---|---|---|---|
| 2 vCPU | DEFAULT | all-respond | ~200 s | 0.020 s |
| 2 vCPU | DEFAULT | timeout | 303 s | 0.030 s (high-CPU fired) |
| 8 vCPU | DEFAULT | timeout | 286 s | 0.029 s |
| 8 vCPU | **DEDICATED** | timeout | **85.6 s** | **0.0086 s → ~117 IP/s** |

- Responding targets are **faster** per IP than non-responders, so a store estate (mostly responding)
  is cheaper than a blind sweep of empty space.
- **9,000 known store addresses ≈ 77 s of sweep on ONE 8-vCPU AG** at DEDICATED. **[E]**
- Full blind `10.*.*.252` space (65,536) ≈ **9.3 min** on one AG. **[E]**
- Conclusion: autodiscovery sizing is governed by **config-count limits**, not throughput.

### 1b. SNMP monitoring (`snmp-generic-device`) of ~20,000 devices — **the real load** [E/U]
This is continuous polling (ifTable/ifXTable walks per interval), not a one-shot probe.

**Load scales with interface count, not device count.** Only datapoint on this bed: 50 devices ×
2 interfaces (= 100 interfaces), `SNMP Health` + `Interfaces`, 1-min interval → **loadavg 0.14 on
4 vCPU** **[M]**. That is ~3.5% of a 4-core box, i.e. ~0.14 cores for 100 interfaces.

⚠️ **Do not fleet-size off that number.** At loadavg 0.14 most of the cost is fixed EEC/datasource
baseline, not marginal per-interface work, so naive linear scaling (which would imply ~100+ AGs for
480,000 interfaces) is unreliable in both directions. **A pilot at 500–1,000 real devices on one AG is
required to get a defensible per-AG device ceiling.** **[U]**

**Metric volume is likely the binding constraint, and it is calculable** **[E]**:

| Assumption | 1-min interval | 5-min interval |
|---|---|---|
| 20,000 devices × 24 interfaces = **480,000 interfaces**, ~8 series/interface | ~3.8 M dp/min ≈ **5.5 B/day** | ~0.77 M dp/min ≈ **1.1 B/day** |

Also implies ~20,000 `EXT_NETWORK_DEVICE` + ~480,000 `EXT_NETWORK_INTERFACE` ≈ **0.5 M entities**.
Check tenant entity ceilings and DDU/licensing **before** rollout — this, not CPU, is what usually
decides the design.

### 1c. ICMP — 90,000 tests — **no data, needs a pilot** [U]
- **Network physics is trivial:** 90,000 probes/min ≈ 1,500 pps. Irrelevant load on a NIC.
- **The question is the execution mechanism, not the packets.** Dynatrace ICMP availability normally
  runs as Synthetic *network availability* monitors on a Synthetic-enabled private AG; 90,000 targets
  is far outside typical synthetic sizing (per-monitor target counts, execution slots, and one entity
  per monitor/target all become limits). This project never measured it.
- **Recommended pilot:** one AG, ~1,000 ICMP targets at the intended cadence → record AG CPU, execution
  duration vs interval, and entity/DDU growth; scale linearly and re-check at 5,000.
- **Alternative if synthetic sizing doesn't fit:** batch ICMP through an extension/`fping`-style sweep
  (far cheaper per target, but you give up the synthetic UI/SLO semantics).

### Bottom line on Q1
- Autodiscovery of 9,000–65,536 addresses: **yes, one or a few AGs.** **[M/E]**
- 20,000-device SNMP *monitoring*: **a fleet, and the sizing input you don't have yet.** Metric volume
  and licensing will likely bind before CPU. **Pilot at 500–1,000 devices.** **[U]**
- 90,000 ICMP: **unknown by mechanism, not by packet rate. Pilot it.** **[U]**
- **Never co-locate** heavy monitoring and large sweeps on the same AG (sweep bursts trip the
  high-CPU detector — observed even on 8 vCPU at DEDICATED). **[M]**

---

## 2. Autodiscovery configs for a fixed last octet (`10.[0-255].[0-255].252`)

### The core constraint
A fixed last octet is **not expressible as a CIDR**, so each target must be enumerated as its own
`/32` entry. Hard limits **[M]**:

| Limit | Value |
|---|---|
| addresses per group | **100** |
| groups per config | **100** |
| → addresses per config | **10,000** |
| configs per AG group | **100** |
| → addresses per AG group | **1,000,000** |

`10.[0-255].[0-255].252` = 256 × 256 = **65,536** addresses.

### ★ Preferred: enumerate only the store subnets you actually have
9,000 stores = **9,000 `/32` entries → fits in ONE config** (90 groups of 100) and sweeps in ~77 s.
Blind-sweeping 65,536 to find 9,000 devices is 7× the work for no extra information if you have the
store list in IPAM/CMDB/DHCP. Use the blind sweep only to *discover unknown* stores, on a slow cadence.

### Blind-sweep layout (aligned, debuggable) — 8 configs per octet
Dense packing gives 7 configs (6 × 10,000 + 5,536) but produces ugly, unaligned ranges. Prefer
**32 second-octets per config**, which keeps every boundary human-readable and leaves headroom:

```
config k (k = 0..7):   covers b ∈ [32k .. 32k+31]
  groups:              one per (b, c-chunk), c-chunks = 0-99, 100-199, 200-255   → 3 groups per b
  per config:          32 b × 3 = 96 groups  (≤100 ✓),  32 × 256 = 8,192 addresses (≤10,000 ✓)
  total:               8 configs × 8,192 = 65,536 ✓
```
Group label convention: `b017-c100` (= `10.17.100-199.252`) so a failing group names its own range.

Config JSON shape (4.3.4 — scanner is **profile**-based; `frequency` in minutes):
```json
{"scope":"ag_group-<group>","value":{"enabled":true,"version":"4.3.4",
 "featureSets":["self-monitoring"],"activationContext":"REMOTE",
 "pythonRemote":{"groups":[
   {"label":"b000-c000","addresses":["10.0.0.252/32","10.0.1.252/32","…100 total…"],
    "port":161,"authentication":{"version":"SNMPv2c","useCredentialVault":false,"community":"<comm>"}}
  ],
  "scanner":{"frequency":720,"profile":"DEDICATED","token":"<dt0s… platform token>"}}}}
```

### Multiple last octets (.252, .250, .1 …)
Each additional octet adds another 65,536 addresses / 8 configs. Against the 100-configs-per-AG-group
ceiling: **up to 12 octets per AG group** with the aligned scheme (96 configs), or 14 with dense
packing (98 configs). Beyond that, add AG groups. **[E]**

---

## 3. Heuristics

**Autodiscovery sweeping**
1. **~117 IP/s per 8-vCPU AG at `DEDICATED`** (timeout-bound worst case, lab LAN). Sizing:
   `seconds ≈ addresses ÷ 117`. Halve your expectation over WAN until measured. **[M/U]**
2. **Concurrency buys speed; cores buy headroom.** 2→8 vCPU barely changed duration (303→286 s) but
   cleared CPU saturation; `DEFAULT`→`DEDICATED` cut it 3.3×. **[M]**
3. **`DEDICATED` only at ≥8 vCPU.** On 2 vCPU it makes the high-CPU alert worse. **[M]**
4. **`frequency` MUST exceed `scan_duration`** — aim ≥2× margin. A 5-min config whose scan takes 303 s
   logs `run_in_thread … longer than the interval` every cycle. Production 720 min is safe. **[M]**
5. **Enumerate known subnets over blind sweeps** — 9,000 targets (1 config) vs 65,536 (8 configs).
6. **Stagger config start times** (or vary `frequency` slightly) so 8+ configs don't all fire at once
   on the same AG.
7. **Responding ranges are cheaper per IP than empty space** — size on the timeout rate, which is the
   pessimistic case. **[M]**
8. **The `.252` enumeration is the whole trick**: it collapses a /8 (16.7 M) to 65,536 — a 256×
   reduction that makes /8-scale coverage a single-AG job. Full-/8 sweeps are bounded by the
   1 M-addresses-per-AG-group limit, not by speed. **[M]**

**SNMP monitoring (`snmp-generic-device`)**
9. **Size by interfaces, not devices.** A 48-port switch costs ~24× a 2-port sim device.
10. **Three levers, in order of impact:** (a) **interval** — 1→5 min cuts volume 5×; (b) **interface
    filtering** via config vars `if_name`, `if_oper_status`, `if_admin_status` (confirmed in
    `extension.yaml`) — skip down/unused ports, which on retail switches is often most of them;
    (c) **featureSets** — enable only what you alert on (`SNMP Health`, `Interfaces`; skip
    `Interfaces 32-bit`+`64-bit` together, `Traffic`, `Control Plane`, `UDP and TCP`,
    `Advanced interfaces`).
11. **Recordings/devices must answer every OID an enabled featureSet polls**, or the endpoint errors
    (`INVALID_CONFIG_ERROR: Text-type oid used as metric value` when a walk overruns a sparse table). **[M]**
12. **Entity identity needs a real chassis MAC** (`EXT_NETWORK_DEVICE` id = `chassis.mac`, supplied by
    the datasource, not an OID). Real devices are fine; this only breaks simulators. **[M]**

**Both**
13. **Dedicated AG groups per role** — one for sweeps, one for monitoring; scope configs by AG group
    so assignment is deterministic. **[M]**
14. **Calibrate before committing:** one region / 500–1,000 devices / 1,000 ICMP targets, then
    extrapolate. Every number here from a 50-device or LAN-latency baseline deserves that check.
15. **Budget entities and DDUs first.** ~0.5 M entities and ~1 B+ datapoints/day at 5-min intervals
    will decide the architecture before CPU does.

---

## Open items to pilot (ranked)
1. **ICMP mechanism + per-AG ceiling** at 1,000 targets — the largest unknown (90,000 planned). **[U]**
2. **Per-AG device ceiling for generic-device** at 500–1,000 real devices, with real port counts. **[U]**
3. **WAN-latency effect** on sweep throughput from one real region. **[U]**
4. **Tenant entity + DDU ceilings** for ~0.5 M entities / ~1 B dp/day. **[U]**

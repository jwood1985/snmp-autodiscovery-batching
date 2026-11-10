# Simulating ~50k devices topologically — feasibility & sizing

_Status 2026-11-10. Based on live mid-scale testing on the `qof78400` / Azure test bed._

## Question
Can we make ~50,000 simulated SNMP devices appear as **`EXT_NETWORK_DEVICE`** (+ `EXT_NETWORK_INTERFACE`)
Smartscape topology via the `snmp-generic-device` monitoring extension?

## Short answer
**Mechanism: proven. Full scale: feasible but gated by materialization + tenant limits, not by polling.**
A real device and (transiently) a simulated device both materialized as `EXT_NETWORK_DEVICE`. But at
**50 unique sim devices**, entity/metric *registration* did not complete reliably in-test (see Risk),
and that — not CPU — is what must be solved before 50k.

## What was proven (mid-scale, 1 AG = D4s_v5 / 4 vCPU)
1. **`snmp-generic-device` uses the AG's native `snmp` datasource** (`dataSources:["snmp"]`), not pysnmp.
2. **The real blocker was source-address, not GETBULK.** snmpsim behind the local-route trick replied
   from its primary IP `10.20.0.5`, not the queried `10.20.64.x`; the native datasource validates
   response source and discarded the replies. (net-snmp/pysnmp are lenient — they masked it.)
   **Fix: bind snmpsim to the specific destination IPs** (`--agent-udpv4-endpoint=10.20.64.N:161`,
   `net.ipv4.ip_nonlocal_bind=1`). After this, a sim device passed fastcheck and materialized.
3. **Unique identity is required.** Identical recordings dedupe to ONE Smartscape entity (3 sim IPs
   sharing one recording → a single `sim-device`). Distinct devices need unique `sysName`
   (and ideally `sysObjectID`) — e.g. per-device community→recording, or a variation module.
4. **Recordings must cover EVERY featureSet OID.** With `Interfaces` enabled, a recording missing
   `ifXTable` (`1.3.6.1.2.1.31.1.1.1.6/10`) → `INVALID_CONFIG_ERROR: Text-type oid used as metric
   value` (GETBULK walks past the end and a string is read as a Counter64). Include ifTable **and**
   ifXTable.
5. **Polling load is negligible at this scale.** 50 devices @ 1-min, `SNMP Health`+`Interfaces`:
   AG loadavg ~**0.14** on 4 vCPU. CPU/poll is NOT the 50k bottleneck.

## ⚠️ Risk that blocks 50k today
At 50 unique sim devices the config reported **OK / polling all 50**, yet only the real C8000V produced
`device.name`-attributed metrics and a stable entity; the 50 sim devices did **not** fully register as
entities/metrics within the test window (~15 min, through some churn). Until this entity-registration
behavior for many unique SNMP devices is understood/resolved, 50k will not materialize regardless of
infrastructure. **Resolve at 50–100 scale first.**

## 50k build requirements (once the above risk is cleared)
| Dimension | Finding / requirement |
|---|---|
| **Source-match at scale** | 50k UDP endpoints on snmpsim = 50k sockets/FDs — raise `ulimit -n`, expect heavy startup/mem; likely split across multiple snmpsim processes/VMs. Cleaner: patch snmpsim to reply via `IP_PKTINFO` from the received dest (keeps a single wildcard bind). |
| **Unique identity ×50k** | 50k per-IP recordings (scripted) or a variation module deriving `sysName`/`sysObjectID` from the queried IP. ~tens of MB of recordings; trivial disk. |
| **Complete recordings** | Every OID each enabled featureSet polls (system + ifTable + ifXTable, etc.). Minimise featureSets to reduce required OIDs. |
| **Config packing** | generic-device `devices[]` per config: not yet limit-tested beyond 50 (worked). Confirm max devices/config and configs/AG-group before fan-out. |
| **AG fleet (polling)** | Polling is light per device (50 ≈ 0.14 load). CPU-wise a few AGs likely cover 50k; **size by config/concurrency limits and materialization throughput, not CPU.** |
| **Entities & licensing** | 50k devices + interfaces (sim=2/device → ~100k; real devices more) ≈ **150k+ Smartscape entities.** Check tenant entity ceilings and DDU/host-unit licensing on this SE tenant — likely the hard limit. |
| **Materialization latency** | Entity creation observed slow/batchy all session (minutes per handful). At 50k this is a first-order concern; must be characterised. |

## Recommended path
1. Fix the 50-device materialization gap (why unique sim devices don't register) at 50–100 scale.
2. Measure materialization throughput (devices/min to Smartscape) and confirm config device limits.
3. Only then fan out: `IP_PKTINFO` source fix + variation-module identities + minimal featureSets,
   sized against tenant entity/licensing ceilings.

## Test-bed artifacts (for cleanup / continuation)
- snmpsim rebound to `10.20.64.1-50` with per-device recordings `w001..w050.snmprec` (sysName
  `sim-dev-NNN`). Wildcard `0.0.0.0:161` was dropped — restore it to serve the full /18 again.
- Monitoring configs on `ag_group-cloud-snmp`: `d3ff9c1a` (C8000V, OK), `983d744e` (3 sim, public-wood),
  `b7fb4e87` (50 unique sim). Delete the test ones when done (or tear down the RG).

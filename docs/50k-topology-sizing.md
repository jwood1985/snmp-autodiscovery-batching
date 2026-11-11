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

## ⚠️ ROOT CAUSE of "only 1 of 50 materialises" — ENTITY IDENTITY COLLAPSE (diagnosed 2026-11-11)

**Collection is NOT the problem.** The AG runtime status for the 50-device config reads
`Endpoints OK: 50 WARNING: 0 ERROR: 0` — the extension successfully polls all 50.

**All simulated devices upsert into ONE `EXT_NETWORK_DEVICE` entity.** `smartscapeNodes` holds exactly
2 nodes (1 sim + the real C8000V), and the sim node's attributes **rotate** between devices on each poll:

| observed at | name | snmp.ip | snmp.sys_object_id |
|---|---|---|---|
| 21:40 | `sim-dev-024` | – | – |
| 02:47 | `sim-device` | 10.20.64.2 | .1.3.6.1.4.1.8072.3.2.10 |
| 03:01 | `sim-dev-048` | 10.20.64.48 | – |
| 03:23 | `sim-dev-005` | 10.20.64.5 | .1.3.6.1.4.1.8072.3.2.5 |

One entity, one `interface_count: 2`, fields overwritten by whichever device polled last. Confirmed with
the second (3-device) config **deleted**, so it is not an artifact of a shared recording.

**The distinguishing attribute is hardware identity.** The sim node has `chassis_mac: "n/a"`,
`mac: ["n/a"]`, `cdp.device_id: "n/a"`; the real Cisco has `chassis_mac: 00:0D:3A:97:49:68` and
`cdp.device_id: vm-c8000v` and keeps a stable, separate entity. Entity upsert is driven by
`troubleshooting.upsert_source: extension:snmp-generic-device|metric:sysuptime`. With no hardware
identity, every device hashes to the same entity ID.

**Ruled out as sufficient for a unique identity** (all made unique per device, collapse persisted):
`sysName`, `sysDescr`, `sysObjectID`, `sysContact`, `sysLocation`, `sysUpTime`,
`ifPhysAddress` (1.3.6.1.2.1.2.2.1.6), `dot1dBaseBridgeAddress` (1.3.6.1.2.1.17.1.1.0),
`lldpLocChassisId` (1.0.8802.1.1.2.1.3.2.0). None of these populated `chassis_mac`.

**Next candidates (untested — blocked by tooling at end of session):** ENTITY-MIB `entPhysicalTable`
(`1.3.6.1.2.1.47.1.1.1.1.5`=class 3/chassis, `.11`=serial, `.13`=model) and CDP
`cdpGlobalDeviceId` (`1.3.6.1.4.1.9.9.23.1.3.4.0`) — CDP is directly implicated because the entity
exposes a `cdp.device_id` field that is populated for the Cisco and `n/a` for sims.

**Consequence for 50k:** unique *identity* is the gate, not CPU, not SNMP. Until a simulated device can
present a hardware identity the extension accepts, **N sim devices → 1 entity for any N.** Metrics show
the same pattern: only the real device produced `device.name`-attributed series (both gauge `if.status`
and counter `if.bytes_in.count`).

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
1. **Solve identity collapse first** (see root cause above) — find the OID(s) that populate
   `chassis_mac` / `cdp.device_id`. Try ENTITY-MIB `entPhysicalTable` + `cdpGlobalDeviceId` next.
   Success criterion: 2 sim devices → **2** `EXT_NETWORK_DEVICE` entities. Nothing else matters until
   this passes — it is a ~7-minute test loop (edit recordings → restart snmpsim → re-count entities).
   Fastest alternative if OID guessing stalls: read the 3.1.5 extension bundle's `extension.yaml`
   (download the extension zip from the Hub/API) and look at how the device entity's
   `id`/`instance` is composed — that names the exact OIDs instead of guessing.
2. Then measure materialization throughput (devices/min to Smartscape) and confirm config device limits.
3. Only then fan out: `IP_PKTINFO` source fix + per-device identities + minimal featureSets,
   sized against tenant entity/licensing ceilings.

## Test-bed artifacts (for cleanup / continuation)
- snmpsim rebound to `10.20.64.1-50` with per-device recordings `w001..w050.snmprec` (sysName
  `sim-dev-NNN`). Wildcard `0.0.0.0:161` was dropped — restore it to serve the full /18 again.
- Monitoring configs on `ag_group-cloud-snmp`: `d3ff9c1a` (C8000V, OK), `983d744e` (3 sim, public-wood),
  `b7fb4e87` (50 unique sim). Delete the test ones when done (or tear down the RG).

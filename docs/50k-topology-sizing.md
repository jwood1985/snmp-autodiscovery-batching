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

### CONFIRMED from the extension bundle itself (authoritative)
Downloaded `snmp-generic-device` **3.1.5** (`GET /platform/extensions/v2/extensions/<ext>/3.1.5`,
Accept: application/octet-stream → zip → inner `extension.zip`) and read its definition:

**`openpipeline/metrics.pipeline.json`** — the gen3 node identity is a *single* component:
```json
"smartscapeNode": { "nodeType": "EXT_NETWORK_DEVICE",
  "idComponents": [ { "idComponent": "identifier", "referencedFieldName": "chassis.mac" } ] }
```
→ **`EXT_NETWORK_DEVICE` ID = `chassis.mac` and nothing else.** Node name comes from `sys.name`,
which is why the single collapsed entity's name rotates between devices.

**`extension.yaml` (line ~359)** — where `chassis.mac` comes from:
```yaml
- key: chassis.mac
  value: this:device.chassis_mac      # NOT an OID — an AG datasource-provided property
# TODO: Enable with 1.333 release
# Dependency is on `this:device.chassis_mac` property handling in DS
```
→ **`chassis.mac` is not SNMP-readable.** No `.snmprec` content can set it, which is why unique
`ifPhysAddress` / `dot1dBaseBridgeAddress` / `lldpLocChassisId` all failed. Every simulated device
therefore yields the same (empty/`n/a`) identifier → **one entity for any N.**

Interfaces have the same dependency: `idPattern: network_interface_{mac.address}_{if.name}` and
`mac.address` carries `filter: const:$and($not($eq(n/a)), $not($eq()))  # required by network topology`
→ no MAC, no `EXT_NETWORK_INTERFACE`.

Also note the **classic** type is keyed differently — `idPattern: network_device_{device.address}`
(per-IP, would scale) — but no classic `network:device`/`custom_device` entities appeared for the sims
in this tenant, so it is not a usable workaround as-is.

**Open sub-question (cheap to settle next):** how the DS computes `device.chassis_mac`. The Cisco's value
`00:0D:3A:97:49:68` is its real Azure NIC MAC, and the AG's ARP table shows only the Azure fabric MAC
(`12:34:56:78:9a:bc`) for all VNet IPs — so it is **not** from ARP, implying the DS derives it from
SNMP `ifPhysAddress` (1.3.6.1.2.1.2.2.1.6). Unique `ifPhysAddress` was added to the sims via snmprec
`4x` hex but `chassis_mac` stayed `n/a` — **unverified whether that hex encoding is valid on the wire.**
Next step: `snmpwalk -On -v2c -c w007 10.20.64.7 1.3.6.1.2.1.2.2.1.6` and compare the value/format with
the Cisco's. If the sim returns a well-formed MAC and `chassis_mac` is still `n/a`, the property is
platform-derived and simulation of many distinct devices is **not possible behind a routed range** —
each sim device would need to sit on the AG's own L2 segment with its own MAC.

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
1. **Settle `device.chassis_mac` (one test, ~10 min).** `snmpwalk` ifPhysAddress on a sim and compare
   format with the Cisco. Success criterion for the whole effort: **2 sim devices → 2
   `EXT_NETWORK_DEVICE` entities.**
   - If a valid unique `ifPhysAddress` **does** produce distinct `chassis_mac` → simulation is viable;
     generate per-device MACs and proceed to step 2.
   - If it does **not** → `chassis.mac` is platform/L2-derived and **simulated devices behind a routed
     range can never be topologically distinct.** Options then: (a) each sim device on the AG's own L2
     segment with a unique MAC — in Azure that caps at ~8 NICs/VM, so 50k is impractical; do it on a
     Linux bridge with 50k macvlan endpoints + the AG on the same bridge (tune
     `net.ipv4.neigh.default.gc_thresh3`, bridge fdb); (b) use **real** devices for topology and keep
     the simulator for autodiscovery scale (it already handled 10k sim IPs fine); (c) re-test on a newer
     extension version — the `TODO: Enable with 1.333 release` comment suggests this handling is in flux.
2. Then measure materialization throughput (devices/min to Smartscape) and confirm config device limits.
3. Only then fan out: `IP_PKTINFO` source fix + per-device identities + minimal featureSets,
   sized against tenant entity/licensing ceilings.

## Summary of the three distinct blockers found (in order encountered)
| # | Blocker | Status |
|---|---|---|
| 1 | AG native `ds:snmp` rejects replies whose **source IP ≠ queried IP** (snmpsim on `0.0.0.0` + local route) | **SOLVED** — bind snmpsim to the specific destination IPs |
| 2 | Recording must cover **every featureSet OID** (missing `ifXTable` → `INVALID_CONFIG_ERROR`) | **SOLVED** — full ifTable + ifXTable; result `Endpoints OK: 50` |
| 3 | `EXT_NETWORK_DEVICE` ID = **`chassis.mac`**, which is a **DS property, not an OID** → all sims share one identity | **OPEN** — the 50k gate |

## Test-bed artifacts (for cleanup / continuation)
- snmpsim rebound to `10.20.64.1-50` with per-device recordings `w001..w050.snmprec` (sysName
  `sim-dev-NNN`). Wildcard `0.0.0.0:161` was dropped — restore it to serve the full /18 again.
- Monitoring configs on `ag_group-cloud-snmp`: `d3ff9c1a` (C8000V, OK), `983d744e` (3 sim, public-wood),
  `b7fb4e87` (50 unique sim). Delete the test ones when done (or tear down the RG).

# Handoff — SNMP Autodiscovery Cloud Test Bed (state as of 2026-11-08)

Portable state for continuing in a **self-hosted Claude Code session with `az` CLI access**.
Companion to `docs/cloud-snmp-testbed-plan.md` (full measured results) and
`provisioning/azure-snmp-testbed.sh` (the corrected build script).

Repo: `jwood1985/snmp-autodiscovery-batching` · branch `claude/awesome-curie-mik6ad`.

---

## TL;DR — what's done, what's blocked

- ✅ Throughput campaign complete; results in `docs/cloud-snmp-testbed-plan.md`.
- ✅ Topology question answered (by docs): **autodiscovery does NOT create Smartscape
  entities; the monitoring extension (`snmp-generic-device`) does.**
- ⏳ **ONE thing blocked:** the live topology proof. The `snmp-generic-device` config is
  deployed and armed but erroring `DEVICE_CONNECTION_ERROR` because **`vm-snmpsim` is
  wedged** (guest OS unresponsive — SSH, `az vm run-command`, and reboot all time out).
  **Next action = rebuild `vm-snmpsim` (needs `az`), then the config self-heals.**

---

## Azure infrastructure

- **Subscription:** `8ab59822-f4d2-4576-b34f-58a6d4cdac49` ("DynatraceDemoTest-Liftr-Demo")
- **Resource group:** `rg-snmp-testbed` · **Region:** `centralus`
- **VNet:** `vnet-snmp` `10.20.0.0/16` · **Subnet:** `snet-infra` `10.20.0.0/24` · **NSG:** `nsg-snmp`
  (SSH rule `allow-ssh` source = whatever Cloud Shell IP was last set; re-set on each new shell)
- **Route table `rt-sim`:** route `to-sim` sends `10.20.64.0/18` → next-hop = sim's private IP.
- **Target ranges:** `10.20.64.0/18` = routed to sim (responders). `10.20.128.0/18` = in-VNet
  but unrouted (used as the timeout / non-responder target).

| VM | Size | Role | State |
|---|---|---|---|
| `vm-ag` | **D8s_v5 (8 vCPU)** | ActiveGate, group `cloud-snmp`, EEC profile HIGH, priv IP `10.20.0.4` | **ALIVE** (polling) |
| `vm-snmpsim` | D8s_v5 | snmpsim, owns routed `10.20.64.0/18` (local route on `lo` + NIC IP-fwd + UDR) | **WEDGED — rebuild needed** |
| `vm-c8000v` | D4s_v5 | Cisco Catalyst 8000V NVA (BYOL) | exists; **SNMP never configured on it** |
| `vm-fgt` | D4s_v5 | FortiGate-VM NVA (BYOL) | exists; **SNMP never configured on it** |

**Azure-layer checks on the sim were all GOOD before it wedged:** power=running,
priv IP `10.20.0.5` = route next-hop, NIC `enableIPForwarding=true`. The fault is purely
guest-side (OS hung). SSH timed out (likely no reachable path / wedged), and `az vm
run-command` timed out too (guest agent dead) → hard reboot didn't recover → rebuild.

### ACTION 1 (needs az): rebuild vm-snmpsim
Full block is in the chat handoff and reproduces the corrected cloud-init from
`provisioning/azure-snmp-testbed.sh` lines ~66–126 (snmpsim runs as a **non-root `snmpsim`
user** with `AmbientCapabilities=CAP_NET_BIND_SERVICE` and `Environment=HOME=/opt/snmpsim`
— this is the fix for the earlier `KeyError: 'HOME'` and "must drop privileges" failures).
Steps: `az vm delete vm-snmpsim` (+ its NIC `vm-snmpsimVMNic` + OS disk) → `az vm create`
with that cloud-init (image `Ubuntu2204`, size `Standard_D8s_v5`, `--nsg ""`,
`--custom-data`) → `az network nic update vm-snmpsimVMNic --ip-forwarding true` →
**re-point the UDR** `to-sim` next-hop to the new sim private IP (it may not come back as
`.5`). Wait ~3–4 min for cloud-init pip install; verify with `az vm run-command` that
`snmpsim`+`snmpsim-localroute` are `active`, `0.0.0.0:161` is listening, and
`ip route show table local` has `10.20.64.0/18`.

---

## Dynatrace tenant

- **Tenant:** `qof78400` · platform URL `https://qof78400.apps.dynatrace.com` · SaaS,
  **INTERNAL/SE tenant** (the Hub UI would not upgrade extension versions — install via API/dtctl).
- **CLI:** `dtctl` v0.45.0 built from source (`github.com/dynatrace-oss/dtctl`), context
  `qof78400`. Uses `DT_PLATFORM_TOKEN` env var.

### Credentials the new session must supply (NOT carried over — regenerate/mint)
1. **`az login`** (you have it).
2. **Platform token for dtctl / API** — needs `extensions:definitions:write` (to install
   hub extensions), monitoring-config write, and DQL read (`storage:buckets:read`,
   `storage:smartscape:read`). Export as `DT_PLATFORM_TOKEN`.
3. **Scanner platform token for autodiscovery 4.x** — a **separate** platform token
   (`dt0s…`) with **exactly `storage:buckets:read` + `storage:smartscape:read`**, used as
   `scanner.token` inside the autodiscovery monitoring config. (The 4.x extension rejects a
   classic `dt0c01` token with HTTP 401.)

### Extensions installed (on the tenant)
- `com.dynatrace.extension.snmp-auto-discovery`: **2.4.7, 3.0.0, 4.3.4** → **use 4.3.4**
  (2.4.7 won't build on the AG's Python 3.14; 3.0.0 has the `getOid` crash).
- `com.dynatrace.extension.snmp-generic-device`: **1.2.6, 1.3.0, 1.10.0, 3.1.5** → **use 3.1.5**.
- Install newer from hub: `dtctl create extension --hub-extension <id> --version <v> --no-agent`.

### Monitoring configs (on the tenant right now)
- **`d3ff9c1a-3f1f-34e1-b6e8-8d4074ac20f4`** — `snmp-generic-device` 3.1.5, scope
  `ag_group-cloud-snmp`, 10 devices `10.20.64.1–10`, featureSets `["SNMP Health","Interfaces"]`,
  community `public-wood`. **ENABLED, status ERROR (`DEVICE_CONNECTION_ERROR`)** — waiting on
  the sim. Will self-heal on its next poll once the sim answers.
- All autodiscovery test configs have been **deleted** (results already captured). No
  autodiscovery config is live.

Endpoint for configs:
`https://qof78400.apps.dynatrace.com/platform/extensions/v2/extensions/<extName>/monitoring-configurations`
(POST to create, `/{id}` DELETE, `/{id}/status` GET; `Authorization: Bearer $DT_PLATFORM_TOKEN`).

---

## Config JSON shapes (regenerate in the new session)

**Autodiscovery 4.3.4** (scanner is **profile**-based; `frequency` MUST exceed `scan_duration`):
```json
{"scope":"ag_group-cloud-snmp","value":{"enabled":true,"description":"...","version":"4.3.4",
 "featureSets":["self-monitoring"],"activationContext":"REMOTE",
 "pythonRemote":{"groups":[{"label":"g000","addresses":["10.20.64.0/32", "..."],"port":161,
   "authentication":{"version":"SNMPv2c","useCredentialVault":false,"community":"public-wood"}}],
   "scanner":{"frequency":720,"profile":"DEDICATED","token":"<SCANNER PLATFORM TOKEN dt0s…>"}}}}
```
Limits: ≤100 groups/config, ≤100 addresses/group → ≤10,000 addresses/config; ≤100 configs/group.

**Generic-device 3.1.5** (no token needed; ingests topology via EEC):
```json
{"scope":"ag_group-cloud-snmp","value":{"enabled":true,"description":"...","version":"3.1.5",
 "featureSets":["SNMP Health","Interfaces"],"activationContext":"REMOTE",
 "snmp":{"devices":[{"ip":"10.20.64.1","port":161,
   "authentication":{"type":"SNMPv2c","community":"public-wood"}}]}}}
```

---

## Measured results (already committed to cloud-snmp-testbed-plan.md)

10,000 `/32` targets/config, measured `sfm.snmp_autodiscovery.scan_duration`:

| AG | profile | workload | scan_duration | per-IP | high-CPU |
|---|---|---|---|---|---|
| 2 vCPU | DEFAULT | all-respond | ~200 s | 0.020 s | no |
| 2 vCPU | DEFAULT | timeout | 303 s | 0.030 s | fired |
| 8 vCPU | DEFAULT | timeout | 286 s | 0.029 s | none |
| 8 vCPU | **DEDICATED** | timeout | **85.6 s** | **0.0086 s** | fired once |

- Empty-space sweeps are **I/O-bound** (timeout waits), not CPU-bound; vCPU buys headroom,
  **`scanner.profile` (concurrency) buys speed** → DEDICATED on 8 vCPU = ~117 IP/s.
- `.252` enumeration (65,536 addr) collapses a /8 to **one AG, ~9 min/sweep**. Full /8 is
  bounded by the **100-config × 10k = 1M-address-per-group** limit, not throughput.

---

## Open items / next actions (priority order)

1. **Rebuild `vm-snmpsim`** (ACTION 1 above — needs `az`). Verify it answers:
   `snmpget -v2c -c public-wood 10.20.64.1 1.3.6.1.2.1.1.1.0` from `vm-ag` (or via run-command).
2. **Confirm topology** — once the sim answers, config `d3ff9c1a` reconnects; check:
   `dtctl query 'smartscapeNodes "EXT_NETWORK_DEVICE" | summarize c=count()'` → expect 10.
   `EXT_NETWORK_INTERFACE` will likely be 0 (basic `.snmprec` has no `ifTable`). For full
   device+interface topology, enrich `/opt/snmpsim/data/public-wood.snmprec` with `ifTable`
   OIDs, or point generic-device at the real NVAs (needs SNMP configured on them first:
   Cisco `snmp-server community public-wood RO`; FortiOS `config system snmp community`).
3. **Not-yet-measured (optional):** all-respond at DEDICATED/8 vCPU; the `HIGH` profile
   midpoint; **network overhead** (`az monitor metrics list` Network In/Out on vm-ag & vm-snmpsim
   around a scan, or `/proc/net/dev` deltas); **ICMP** (needs a Synthetic-enabled private AG
   for Dynatrace network-availability monitors — 10k IPs is not a synthetic use case;
   `fping` sweep from the AG for mass ICMP overhead/RTT).
4. **Teardown when done:** `LOC=centralus APPLY=1 provisioning/azure-snmp-testbed.sh teardown`
   (deletes the whole RG — stops all billing).

## Gotchas learned (don't rediscover)
- Fresh Cloud Shell defaults to the **wrong subscription** → `ResourceGroupNotFound`; set
  `az account set --subscription 8ab59822-f4d2-4576-b34f-58a6d4cdac49` first.
- Fresh Cloud Shell loses the SSH key → `az vm user update -g rg-snmp-testbed -n <vm> -u
  azureuser --ssh-key-value "$(cat ~/.ssh/id_rsa.pub)"` and re-set the NSG SSH source to the
  current egress IP. Or skip SSH entirely and use `az vm run-command invoke`.
- The Dynatrace platform tokens and the scratchpad files from the prior session do **not**
  transfer — mint fresh tokens in the new session.

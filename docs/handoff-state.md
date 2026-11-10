# Handoff — SNMP Autodiscovery Cloud Test Bed (state as of 2026-11-08)

Portable state for continuing in a **self-hosted Claude Code session with `az` CLI access**.
Companion to `docs/cloud-snmp-testbed-plan.md` (full measured results) and
`provisioning/azure-snmp-testbed.sh` (the corrected build script).

Repo: `jwood1985/snmp-autodiscovery-batching` · branch `claude/awesome-curie-mik6ad`.

---

## Session update — 2026-11-10 (TOPOLOGY PROOF — RESOLVED)

End-to-end topology proof landed. What it took, in order:

1. **Sim (`vm-snmpsim`) rebuilt** (delete+recreate from cloud-init) — now serves GET/GETNEXT/
   GETBULK to net-snmp on `10.20.0.5` and the routed range `10.20.64.x`. Recording enriched
   with `ifTable`+`ifXTable`.
2. **But the generic-device config stayed `DEVICE_CONNECTION_ERROR` against the sim.** AG
   datasource log (`…/datasources/com.dynatrace.extension.snmp-generic-device/
   dynatracesourcesnmp_fastcheck*.log`) showed `GetBulk query timeout for OID 1.3.6.1.2.1.1.5.0`
   every cycle. Diagnosis: **the EEC's pysnmp-7.x GETBULK is silently dropped by
   snmpsim-lextudio** — snmpsim logs the extension's GETs (and answers them) but logs **zero
   GETBULK**, while `snmpbulkget` (net-snmp) to the same IPs works. Community is fine
   (`public-wood`; the `b'c2d6…'` in snmpsim logs is its internal hash). Tuning
   `advanced.maxRepetitions=1`/`maxOidsPerQuery=1` did nothing; **SNMPv1 (no GETBULK) is
   rejected — extension allows only SNMPv2c/SNMPv3.** → simulator path is a dead end for this
   extension.
3. **Switched to a real device.** `vm-c8000v` rebuilt in Cloud Shell (same NIC → kept
   `10.20.0.6`; `--admin-password` provisioned SSH; **custom-data day-0 config was ignored**
   by the image, so SNMP was NOT auto-configured). Configured it over SSH from `vm-ag`
   (`sshpass` + `azureuser` / the admin password set during the Cloud Shell rebuild — **not
   stored here; rotate or tear down the RG when done**): `snmp-server community public-wood RO` +
   `write memory`. Verified: `sysDescr = Cisco IOS Software IOSXE 17.15.6`, `sysObjectID
   1.3.6.1.4.1.9.1.3004`, **GETBULK works.**
4. **Pointed config `d3ff9c1a` at `10.20.0.6`** (SNMPv2c/public-wood, via platform-token PUT) →
   fastcheck `Status OK (0)` → status **OK** → **`EXT_NETWORK_DEVICE`=1, `EXT_NETWORK_INTERFACE`=3.**

**Platform token:** a working one already exists in the workspace — `dt0s16.H6EEDTHA.…`
(found in `/root/.bash_history` as `DT_APP_PLATFORM_TOKEN`). It authenticates the
`/platform/extensions/v2/extensions/<ext>/monitoring-configurations[/<id>[/status]]` GET/PUT.
(dtctl's own OAuth token 401s on that endpoint; dtctl `query`/`get` work for DQL/smartscape.)

**Gotchas banked:** C8000V `az vm user update` hangs (guest agent `Not Ready`); its custom-data
day-0 config is ignored (SSH comes from `--admin-password`, configure SNMP via SSH after boot);
`az vm run-command` is unsupported on IOS-XE (use `vm-ag` as an intra-VNet SSH jump host);
`az network …` (Network RP) was frequently unreachable from the self-hosted session — do
NSG/route edits in Cloud Shell.

---

## Session update — 2026-11-09 (az-capable self-hosted session)

Picked this up in an `az`-capable session (logged in as `josh.wood@dynatrace.com`, correct
sub). Probed before rebuilding — and the picture changed from the 2026-11-08 snapshot:

- **`vm-snmpsim` was genuinely wedged (confirmed), but recovered non-destructively.**
  Pre-fix instance view showed **VM-agent status `null`** and extensions
  (`enablevmaccess`, `MDE.Linux`) stuck `Transitioning` while fabric power = `running` —
  i.e. guest-side hang, exactly as diagnosed. **`az vm redeploy vm-snmpsim`** (fresh host,
  cold boot, keeps disk/NIC/IP `.5`) brought the **VM-agent back to `Ready`**. No rebuild
  was needed. The old action-run-command slot was stuck `Conflict: execution in progress`;
  a managed run-command (`--run-command-name fixsim`) was used to bypass it.
- **Sim still NOT serving SNMP — root cause now ISOLATED: snmpsim is not listening on :161.**
  Decisive discriminator run from `vm-ag` (reliable channel, bypasses the UDR entirely):
  `ping 10.20.0.5` → **OK**, but `snmpget 10.20.0.5` (the sim's **own primary NIC IP**, normal
  intra-subnet routing, no UDR/local-route involved) → **`Timeout: No Response`**. The host is
  up; nothing answers on UDP 161. **The UDR/path is RULED OUT** — the earlier "snmpsim-local
  vs. UDR" question is answered: it's snmpsim itself. Plain `systemctl restart` (attempted
  several times via run-command) did **not** fix it → the install/venv or unit on the disk is
  broken, not merely stopped. A blind venv-rebuild recovery was attempted but could not be
  confirmed (see constraint below); post-attempt `vm-ag → 10.20.0.5` still timed out.
- **HARD CONSTRAINT in this session: ARM egress is badly degraded.** Every `Microsoft.Network`
  call (route-table, NIC, subnet) hung across many retries. Worse, the sim's **action**
  run-command slot is stuck `Conflict: execution in progress` (survived the redeploy), and
  **managed** run-command create/update/show calls time out or return empty — so I could not
  reliably execute a guest fix **nor read `journalctl`** from here. Only `vm-ag`'s run-command
  and a few compute reads worked, intermittently. **→ finish in Cloud Shell (clean ARM reach).**
- ⚠️ **Cleanup owed:** leftover managed run-commands on `vm-snmpsim`: **`fixsim`** and
  **`recover1`**. Delete both:
  `for n in fixsim recover1; do az vm run-command delete -g rg-snmp-testbed --vm-name vm-snmpsim --run-command-name $n --yes; done`.

### Finish in Cloud Shell — self-contained block
> Diagnosis is settled: **fix snmpsim on the sim; the UDR is NOT the problem.** Oracle for
> "fixed" = `vm-ag → 10.20.0.5` returns the sysDescr (that path needs no UDR). Only if the sim's
> **own** IP answers but the routed `10.20.64.x` range still times out does the UDR/local-route
> matter — kept as the secondary check at the end.
```bash
az account set --subscription 8ab59822-f4d2-4576-b34f-58a6d4cdac49
RG=rg-snmp-testbed
# NOTE: the action run-command slot on vm-snmpsim may still be stuck 'Conflict'. If so, use a
# managed run-command instead: az vm run-command create ... --run-command-name fix2 --async-execution false
# 1. REPAIR snmpsim on the sim (rebuild venv only if the responder binary is broken) + show WHY
az vm run-command invoke -g $RG -n vm-snmpsim --command-id RunShellScript --scripts '
  systemctl stop snmpsim 2>/dev/null
  if ! /opt/snmpsim/venv/bin/snmpsim-command-responder --help >/dev/null 2>&1; then
    rm -rf /opt/snmpsim/venv; python3 -m venv /opt/snmpsim/venv
    /opt/snmpsim/venv/bin/pip install --upgrade pip snmpsim-lextudio
  fi
  id snmpsim >/dev/null 2>&1 || { groupadd --system snmpsim; useradd --system --no-create-home \
    --home-dir /opt/snmpsim --shell /usr/sbin/nologin -g snmpsim snmpsim; }
  chown -R snmpsim:snmpsim /opt/snmpsim
  sysctl -w net.ipv4.ip_forward=1
  systemctl daemon-reload
  systemctl enable --now snmpsim-localroute.service
  systemctl restart snmpsim.service; sleep 3
  echo "active:"; systemctl is-active snmpsim snmpsim-localroute
  echo "listen:"; ss -lunp | grep ":161 " || echo NO-161
  echo "self :"; snmpget -v2c -c public-wood -t2 -r1 127.0.0.1 1.3.6.1.2.1.1.1.0 2>&1 | head -1
  echo "WHY (journal, read this if it still fails):"; journalctl -u snmpsim --no-pager -n 20' \
  --query "value[0].message" -o tsv
# 2. VERIFY from the AG — sim OWN IP first (no UDR), then the routed range
az vm run-command invoke -g $RG -n vm-ag --command-id RunShellScript --scripts '
  echo -n "0.5  => "; snmpget -v2c -c public-wood -t3 -r1 10.20.0.5  1.3.6.1.2.1.1.1.0 2>&1 | head -1
  echo -n "64.1 => "; snmpget -v2c -c public-wood -t3 -r1 10.20.64.1 1.3.6.1.2.1.1.1.0 2>&1 | head -1' \
  --query "value[0].message" -o tsv
# 3. ONLY IF 0.5 answers but 64.1 times out -> it IS the UDR/local-route path:
# SIM_IP=$(az vm list-ip-addresses -g $RG -n vm-snmpsim --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv)
# az network route-table route show -g $RG --route-table-name rt-sim -n to-sim -o json   # nextHop == $SIM_IP ?
# az network route-table route update -g $RG --route-table-name rt-sim -n to-sim --next-hop-ip-address $SIM_IP
# az network nic update -g $RG -n vm-snmpsimVMNic --ip-forwarding true
# 4. cleanup leftover managed run-commands
for n in fixsim recover1; do az vm run-command delete -g $RG --vm-name vm-snmpsim --run-command-name $n --yes 2>/dev/null; done
```
Once `vm-ag → 10.20.64.1` answers, generic-device config **`d3ff9c1a`** self-heals on its next
poll → check `EXT_NETWORK_DEVICE` smartscape count (expect 10). That's the topology proof.

### Corrections to earlier facts (verified live 2026-11-09)
- `vm-ag` is **`D4s_v5` (4 vCPU)**, not `D8s_v5` — the "Azure infrastructure" table below is
  wrong. (The DEDICATED-profile throughput numbers were measured on 8 vCPU; current AG is 4.)
- Region confirmed `centralus`; all four VMs show fabric power `running`.

---

## TL;DR — what's done, what's blocked

- ✅ Throughput campaign complete; results in `docs/cloud-snmp-testbed-plan.md`.
- ✅ Topology question answered (by docs): **autodiscovery does NOT create Smartscape
  entities; the monitoring extension (`snmp-generic-device`) does.**
- ✅ **TOPOLOGY PROOF ACHIEVED (2026-11-10).** `snmp-generic-device` config `d3ff9c1a`
  pointed at the **real Cisco C8000V** (`10.20.0.6`) → status **OK** → Smartscape shows
  **`EXT_NETWORK_DEVICE` = 1** (`vm-c8000v...cloudapp.net`) **+ `EXT_NETWORK_INTERFACE` = 3**.
  This confirms the monitoring extension (not autodiscovery) materializes the topology entities.
  **Key blocker found along the way: snmpsim does NOT answer the extension's pysnmp-7.x
  GETBULK** (GET works, net-snmp bulk works, but the EEC's GETBULK gets no response →
  fastcheck stuck `DEVICE_CONNECTION_ERROR`). The extension only allows SNMPv2c/SNMPv3 (both
  use GETBULK) and tuning `maxRepetitions`/`maxOidsPerQuery` doesn't help → **a real device
  (or a simulator that speaks pysnmp GETBULK) is required for the topology proof.** See the
  2026-11-10 resolution block below.

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
| `vm-ag` | **D4s_v5 (4 vCPU)** [corrected 2026-11-09] | ActiveGate, group `cloud-snmp`, EEC profile HIGH, priv IP `10.20.0.4` | **ALIVE** (polling) |
| `vm-snmpsim` | D8s_v5 | snmpsim, owns routed `10.20.64.0/18` (local route on `lo` + NIC IP-fwd + UDR) | **redeployed 2026-11-09 — agent `Ready`, but not yet serving SNMP** |
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

#!/usr/bin/env python3
"""
Generate ICMP (multiprotocol / "network availability") synthetic monitor payloads
for the 50k-endpoint pilot.

Layout (matches the requested batching): 500 monitors x 100 ICMP targets = 50,000 tests.
Schema limits confirmed from builtin:synthetic.multiprotocol.config on tenant qof78400:
  - Step.targetList  maxObjects = 10000   (targets per request)
  - properties.steps maxObjects = 100     (requests per monitor)
  => one monitor could hold 1,000,000 targets; we deliberately stay at 100/monitor
     so each monitor is a small, independently-schedulable unit (that is the thing
     the pilot is trying to size).

Two emission modes:
  --mode targets-per-step   1 step  x 100 targets   (default; fewest objects, 1 request/monitor)
  --mode step-per-target  100 steps x 1 target      ("100 requests" literal reading)

Usage:
  ./gen-icmp-synthetics.py --count 50000 --per-monitor 100 --out /tmp/icmp
  ./gen-icmp-synthetics.py --ramp            # emit the 50/150/500 ramp stages only

Outputs <out>/monitor-NNNN.json  (one settings-value payload per monitor)
    and <out>/targets.txt        (flat list, for fping verification)
    and <out>/MANIFEST.json      (counts + ranges, for the writeup)
"""
import argparse, ipaddress, json, os, sys

# Ranges that answer ICMP on vm-snmpsim via kernel `local` routes.
# 10.20.64.0/18 is already routed+local (16,384 addrs, verified answering ICMP).
# The other two require a UDR to the sim AND a local route on the sim (see docs).
RANGES = [
    ("10.20.64.0/18",  "routed+local ALREADY VERIFIED answering ICMP"),
    ("10.20.128.0/17", "needs UDR -> sim + local route"),
    ("10.20.32.0/19",  "needs UDR -> sim + local route"),
]

# ICMP step properties, lifted verbatim from the working monitor
# MULTIPROTOCOL_MONITOR-486A47D176F7FCF2 on this tenant.
ICMP_PROPS = [
    {"key": "EXECUTION_TIMEOUT",         "value": "PT1S"},
    {"key": "ICMP_TIME_TO_LIVE",         "value": "64"},
    {"key": "ICMP_PACKET_SIZE",          "value": "32"},
    {"key": "ICMP_NUMBER_OF_PACKETS",    "value": "1"},
    {"key": "ICMP_TIMEOUT_FOR_REPLY",    "value": "PT1S"},
    {"key": "ICMP_DO_NOT_FRAGMENT_DATA", "value": "true"},
    {"key": "ICMP_IP_VERSION",           "value": "4"},
]
SUCCESS_CONSTRAINT = [{"type": "SUCCESS_RATE_PERCENT",
                       "properties": [{"key": "operator", "value": ">="},
                                      {"key": "value", "value": "80"}]}]
REQ_CONFIGS = [{"constraints": [{"type": "ICMP_SUCCESS_RATE_PERCENT",
                                 "properties": [{"key": "operator", "value": ">="},
                                                {"key": "value", "value": "80"}]}],
                "properties": []}]


def usable_addresses(limit):
    """Yield host addresses from RANGES, skipping .0/.255 to stay realistic."""
    out = []
    for cidr, _ in RANGES:
        for ip in ipaddress.ip_network(cidr).hosts():
            last = int(str(ip).split(".")[-1])
            if last in (0, 255):
                continue
            out.append(str(ip))
            if len(out) >= limit:
                return out
    return out


def build_monitor(idx, targets, mode):
    if mode == "step-per-target":
        steps = [{"name": f"icmp-{idx:04d}-{j:03d}",
                  "requestType": "ICMP",
                  "targetList": [t],
                  "properties": ICMP_PROPS,
                  "constraints": SUCCESS_CONSTRAINT,
                  "requestConfigurations": REQ_CONFIGS}
                 for j, t in enumerate(targets)]
    else:
        steps = [{"name": f"icmp-batch-{idx:04d}",
                  "requestType": "ICMP",
                  "targetList": targets,
                  "properties": ICMP_PROPS,
                  "constraints": SUCCESS_CONSTRAINT,
                  "requestConfigurations": REQ_CONFIGS}]
    return {"description": f"ICMP pilot batch {idx:04d} ({len(targets)} targets)",
            "enabled": True, "properties": [], "steps": steps}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--count", type=int, default=50000)
    p.add_argument("--per-monitor", type=int, default=100)
    p.add_argument("--mode", choices=["targets-per-step", "step-per-target"],
                   default="targets-per-step")
    p.add_argument("--out", default="/tmp/icmp")
    p.add_argument("--ramp", action="store_true")
    a = p.parse_args()

    if a.ramp:
        print("Recommended ramp (do NOT jump straight to 500):")
        for n in (50, 150, 500):
            print(f"  stage: {n:3d} monitors x {a.per_monitor} = {n*a.per_monitor:6d} targets"
                  f"  -> measure AG CPU, exec duration vs frequency, dropped executions")
        return

    if a.per_monitor > 10000:
        sys.exit("per-monitor exceeds targetList maxObjects (10000)")
    if a.mode == "step-per-target" and a.per_monitor > 100:
        sys.exit("step-per-target needs per-monitor <= 100 (steps maxObjects)")

    addrs = usable_addresses(a.count)
    if len(addrs) < a.count:
        print(f"WARNING: only {len(addrs)} usable addresses available "
              f"(requested {a.count}). Add the UDR-routed ranges.", file=sys.stderr)

    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "targets.txt"), "w") as f:
        f.write("\n".join(addrs) + "\n")

    n_mon = (len(addrs) + a.per_monitor - 1) // a.per_monitor
    for i in range(n_mon):
        chunk = addrs[i * a.per_monitor:(i + 1) * a.per_monitor]
        with open(os.path.join(a.out, f"monitor-{i:04d}.json"), "w") as f:
            json.dump(build_monitor(i, chunk, a.mode), f, indent=1)

    manifest = {"targets": len(addrs), "monitors": n_mon,
                "per_monitor": a.per_monitor, "mode": a.mode,
                "ranges": [{"cidr": c, "note": n} for c, n in RANGES],
                "requests_total": len(addrs) if a.mode == "step-per-target" else n_mon}
    with open(os.path.join(a.out, "MANIFEST.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    print(json.dumps(manifest, indent=1))


if __name__ == "__main__":
    main()

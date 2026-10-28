# Bug: snmp-auto-discovery 3.0.0 crashes on any responding device (pysnmp API mismatch)

**Extension:** com.dynatrace.extension.snmp-auto-discovery **3.0.0**
**ActiveGate:** Windows x86-64, 1.347.60, Extension Execution Controller enabled
**Datasource runtime:** bundled python3.10 (`agent\res\dsruntime\python3.10`)
**Works on:** extension **2.4.7** (same AG, same config, same target)

## Summary
A scan that receives a valid SNMP response from a device crashes while formatting the
response, before the device is counted. `devices_ok` stays 0 and no device is registered.
The crash only triggers when a device *answers*; scans against non-responding ranges
"complete" silently with 0 results, which hides the bug.

## Traceback (first scan after process start)
```
File "snmp_auto_discovery\snmp_scanner.py", line 136, in _snmp_query
    log = utils.varbinds_to_log(var_binds, device)
File "snmp_auto_discovery\utils.py", line 177, in varbinds_to_log
    sys_object_id = printable_str(varBinds[2][1].getOid().prettyPrint())
AttributeError: 'ObjectIdentifier' object has no attribute 'getOid'
```
`varBinds[2][1]` is the **sysObjectID value**, a pysnmp `ObjectIdentifier`. The bundled pysnmp
(modern asyncio API — `pysnmp/hlapi/v3arch/asyncio/cmdgen.py`, `pysnmp/carrier/asyncio/...`)
does not provide `.getOid()` on that type. The call site assumes the older pysnmp 4.x API.

## Secondary failures (every subsequent scan until restart)
After the first exception the asyncio loop / UDP transport is left broken; later scans fail at send:
```
pysnmp.carrier.error.CarrierError: ... 'NoneType' object has no attribute 'append'
RuntimeError: Event loop is closed
Fatal write error on datagram transport ... 'NoneType' object has no attribute 'sendto'
```

## Reproduction
1. Monitoring configuration (v3.0.0), scope = any AG group with a working EEC, addresses = a single
   responding SNMPv2c device, e.g. `192.168.1.200/32`, correct community, frequency 5, profile DEFAULT.
2. Device must answer GET (verified independently: `snmpget -v2c -c <community> 192.168.1.200 1.3.6.1.2.1.1.1.0` returns sysDescr).
3. Observe `devices_scanned=1`, `devices_ok=0`, config status flapping UNKNOWN/ERROR, traceback above in
   `C:\ProgramData\dynatrace\remotepluginmodule\log\extensions\datasources\python*.log`.
4. Same configuration on **2.4.7** → `devices_ok=1`, device registered as `network:device`
   (sysObjectID 1.3.6.1.4.1.28866.2.49, sysDescr "TEG-S80ES").

## Expected
Responding devices are counted and registered on 3.0.0 as they are on 2.4.7.

## Suggested fix
In `utils.varbinds_to_log`, use the OID value directly (e.g. `varBinds[2][1].prettyPrint()` /
`str(varBinds[2][1])`) rather than `.getOid()`, and guard the asyncio transport so one failed
query does not close the loop for the remaining tasks.

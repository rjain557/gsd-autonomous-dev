# Edge Telemetry Catalog

The authoritative catalog of what each Edge plugin emits. ComplianceAgent uses
this to map telemetry events → framework controls.

Source of truth lives in the Edge codebase manifest; this file is a snapshot
that is regenerated on Edge releases. Treat the manifest in `tech-web-edge/`
as canonical when the two disagree.

## Schema

Every telemetry event carries:
```
{
  event_id: string,           # UUID
  host_id: string,            # SHA256(serial + macs + machine_guid)
  client_id: string,
  site_id: string,
  tenant_id: string,
  plugin: string,             # plugin name
  event_type: string,         # see catalog below
  occurred_at_utc: string,
  source_vendor: string,      # for telemetry from sources like CrowdStrike / Huntress
  source_event_id?: string,   # vendor's native event id (for dedup)
  payload: object             # event-type-specific
}
```

## Catalog by plugin

### WindowsEndpoint
| event_type | What it emits | Cadence | Maps to controls (examples) |
|---|---|---|---|
| `endpoint.boot` | Boot sequence + integrity check | Per boot | HIPAA §164.312(a)(2)(i), SOC2 CC6.6, NIST AC-2 |
| `endpoint.login` | User login event w/ MFA status | Per login | HIPAA §164.308(a)(5)(ii)(D), PCI 8.3, CMMC AC.L2-3.1.1 |
| `endpoint.policy_state` | Local security policy snapshot | Hourly | NIST CM-2, ISO A.9.1.1 |
| `endpoint.disk_encryption` | BitLocker/FileVault state | Daily | HIPAA §164.312(a)(2)(iv), PCI 3.4 |
| `endpoint.patch_state` | Installed/missing patches | Daily | NIST SI-2, CMMC SI.L2-3.14.1 |
| `endpoint.hardware_fingerprint` | Asset entity update | On change | NIST CM-8, ISO A.8.1.1 |
| `endpoint.av_state` | Defender + AV product state | Hourly | NIST SC-7, PCI 5.x |
| `endpoint.tamper` | Edge SelfGuard tamper detection | On detect | NIST SI-7 |

### LinuxEndpoint
| event_type | What it emits | Cadence | Maps to controls |
|---|---|---|---|
| `endpoint.boot` | Boot sequence + integrity | Per boot | HIPAA §164.312(a)(2)(i), SOC2 CC6.6 |
| `endpoint.login` | SSH/console login | Per login | PCI 8.3, CMMC AC.L2-3.1.1 |
| `endpoint.audit_d` | auditd events | Continuous stream | NIST AU-2, HIPAA §164.312(b) |
| `endpoint.policy_state` | SELinux/AppArmor state | Hourly | NIST AC-3 |
| `endpoint.disk_encryption` | LUKS state | Daily | HIPAA §164.312(a)(2)(iv) |
| `endpoint.patch_state` | apt/yum patch state | Daily | NIST SI-2 |
| `endpoint.hardware_fingerprint` | Asset entity update | On change | NIST CM-8 |

### SqlServer
| event_type | What it emits | Cadence | Maps to controls |
|---|---|---|---|
| `sql.health` | Connection + free-space + wait-stats | 15m (tiered) | NIST CP-9, SOC2 CC7.1 |
| `sql.tripwire` | Sev-1: log full / IO latency burst | 3m | NIST CP-2 |
| `sql.posture` | DB owner mapping, encryption, audit | 12h | HIPAA §164.312(b), NIST AU-2 |
| `sql.log_pressure` | Transaction log usage % + VLF count | 15m | NIST CP-9 |

### Nakivo / Veeam (backup plugins)
| event_type | What it emits | Cadence | Maps to controls |
|---|---|---|---|
| `backup.job_status` | Per-job success/failure + RPO | Per job | HIPAA §164.308(a)(7), NIST CP-9, FedRAMP CP-9 |
| `backup.repo_inventory` | Storage available / used | Hourly | NIST CP-9 |
| `backup.restore_test` | Restore-verification run | Weekly | HIPAA §164.308(a)(7)(ii)(D) |

### vCenter
| event_type | What it emits | Cadence | Maps to controls |
|---|---|---|---|
| `vsphere.vm_inventory` | VM list + power state + tags | Hourly | NIST CM-8 |
| `vsphere.snapshot_state` | Snapshot age + count | Daily | NIST CM-2 |
| `vsphere.host_health` | ESXi host metrics | 15m | NIST CP-2 |
| `vsphere.audit_events` | vCenter audit log | Continuous | NIST AU-2 |

### SnmpPoller (network gear)
| event_type | What it emits | Cadence | Maps to controls |
|---|---|---|---|
| `net.interface_state` | up/down + errors/discards | 5m | NIST SC-7 |
| `net.config_drift` | Running-config vs baseline | Daily | NIST CM-2, CMMC CM.L2-3.4.2 |
| `net.acl_state` | ACL entries snapshot | Daily | NIST AC-3 |

### UserActivity (Teramind replacement plugin)
| event_type | What it emits | Cadence | Maps to controls |
|---|---|---|---|
| `useract.session` | Login session start/end + idle | Per session | HIPAA §164.312(a)(2)(iii) |
| `useract.process_exec` | Hash + signer of executed programs | Per exec | NIST AC-2, ISO A.12.5.1 |
| `useract.usb_event` | USB insert/remove + device serial | Per event | NIST AC-19, PCI 9.5.1 |
| `useract.print` | Print job metadata (no content) | Per job | HIPAA §164.310(d)(2) |
| `useract.clipboard_anomaly` | Large-volume clipboard event | On threshold | DFARS 252.204-7012 |

**Privacy note**: UserActivity events are subject to per-jurisdiction consent
flows. Edge will not emit these events without verified client + employee consent
captured by LegalAgent-drafted consent forms.

### MdmIos / MdmAndroid (Intune/Jamf replacement plugins)
| event_type | What it emits | Cadence | Maps to controls |
|---|---|---|---|
| `mdm.device_inventory` | Device list + OS version | Daily | NIST CM-8 |
| `mdm.compliance_state` | Per-device compliance result | Hourly | HIPAA §164.310(d)(1) |
| `mdm.app_inventory` | Installed app list | Daily | NIST CM-8 |
| `mdm.profile_state` | Config profile status | On change | NIST CM-2 |
| `mdm.remote_wipe_audit` | Remote-wipe execution record | Per event | HIPAA §164.310(d)(2)(i) |

### HostRemediator (L1 actuator)
| event_type | What it emits | Cadence | Maps to controls |
|---|---|---|---|
| `actuator.operation` | Catalog op execution record | Per op | NIST AU-2, SOC2 CC6.8 |
| `actuator.dry_run_result` | Dry-run preview output | Per dry-run | (internal) |

### LanIpActuator
| event_type | What it emits | Cadence | Maps to controls |
|---|---|---|---|
| `lanip.operation` | IP-device action (printer / phone / scanner) | Per op | NIST AU-2 |

### PatchManager (ME-EC replacement)
| event_type | What it emits | Cadence | Maps to controls |
|---|---|---|---|
| `patch.scan` | Available patches per host | Daily | NIST SI-2, CMMC SI.L2-3.14.1 |
| `patch.applied` | Patch installation event | Per patch | NIST SI-2, HIPAA §164.308(a)(5) |
| `patch.deferred` | Patches blocked by policy | Daily | NIST SI-2, audit trail |

### SelfGuard (Edge integrity)
| event_type | What it emits | Cadence | Maps to controls |
|---|---|---|---|
| `selfguard.heartbeat` | Edge attestation | Per heartbeat | NIST SI-7 |
| `selfguard.tamper_detected` | Integrity violation | On detect | NIST SI-7, IR-4 |
| `selfguard.peer_attestation` | Peer-requested integrity check | On request | (internal) |
| `selfguard.dns_anomaly` | Unexpected DNS resolution | On detect | NIST SC-20 |

## Cross-plugin correlation

ComplianceAgent should use `host_id` + `client_id` + `occurred_at_utc ± 5s`
as the dedup key when multiple plugins emit overlapping events (e.g., both
`endpoint.av_state` and a CrowdStrike-bridge plugin emitting AV status).

## Update log

- 2026-06-01: initial catalog. Sources: myJian platform-coverage decision §4 plugin roster + Edge telemetry contract from §10.3.

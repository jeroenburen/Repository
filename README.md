# 🗂️ Personal Repository

A personal collection of PowerShell scripts and apps for VMware/vSphere infrastructure, NSX networking, Windows administration, and home energy monitoring.

---

## 📁 Repository Structure

```
root/
├── scripts/
│   ├── backup/            # Backup and restore
│   ├── configuration/     # System and VM configuration
│   │   ├── hosts-clusters/
│   │   └── virtual-machines/
│   ├── management/        # Day-to-day management tasks
│   │   └── vcf/           # VMware Cloud Foundation
│   ├── networking/        # NSX and VDS networking
│   │   └── nsx migration toolkit/
│   └── personal/          # Personal/home scripts
├── lib/                   # Shared helper functions
└── apps/
    └── energie-dashboard/ # Local energy monitoring app
    └── etf-tracker/       # Tracker for ETF portfolio
    └── money-tracker/     # Personal Finance Tracker
```

---

## 📚 Library (`lib/`)

Shared utilities intended to be dot-sourced by other scripts.

| Script | Description |
|--------|-------------|
| `Functions.ps1` | Shared function library: `Get-ScriptDirectory` and a `Log` function (console / file / both output modes) |
| `Convert-CSV-to-XLSX.ps1` | Combines all CSV files in a folder into a single Excel workbook, one sheet per CSV. Requires the `ImportExcel` module |
| `Test-Credentials.ps1` | Prompts for credentials and validates them against the current Active Directory domain via LDAP |
| `Upgrade-PowerCLI.ps1` | Removes outdated VMware PowerCLI module versions and installs the latest |
| `Use-Credentials.ps1` | Snippet for connecting to Microsoft Online Services using a PSCredential object |
| `WakeOnLAN.ps1` | Sends a Wake-on-LAN magic packet via UDP broadcast to wake a remote device by MAC address |

---

## 💾 Backup (`scripts/backup/`)

| Script | Description |
|--------|-------------|
| `Backup-DnsZones.ps1` | Exports all non-auto-created DNS zones from a domain controller and copies the backup files to a local folder |

---

## ⚙️ Configuration (`scripts/configuration/`)

| Script | Description |
|--------|-------------|
| `Activate-MAK.ps1` | Activates a Windows server using a Multiple Activation Key (MAK) via `slmgr.vbs`, with retry logic and status verification |
| `Configure-WinRM.ps1` | Configures WinRM over HTTPS: creates a self-signed cert, sets up an HTTPS listener, and adds a firewall rule for port 5986 |
| `New-KrbtgtKeys.ps1` | Resets the KrbTgt account password for RWDCs and RODCs in a controlled manner. Supports test and production modes. Community script by Jorge de Almeida Pinto (MVP) |
| `UploadVMwareTools.ps1` | Uploads the latest VMware Tools offline bundle to the `vmtools` folder on all SSD datastores and installs it on all ESXi hosts via ESXCli |

### Hosts & Clusters

| Script | Description |
|--------|-------------|
| `Remove-VIB.ps1` | Removes a specific Cisco VIB (`cisco-vem-v320-esx`) from a given ESXi host using ESXCli |
| `Set-DRSWindowsGroups.ps1` | Creates/updates DRS VM/host affinity groups in a vSphere cluster based on definitions read from a CSV file |
| `Set-TeamPolicyUpDelay.ps1` | Sets the `Net.TeamPolicyUpDelay` advanced setting to 300,000 ms on all connected ESXi hosts in a given datacenter |
| `UploadiDRACCertificate.ps1` | Uploads a wildcard SSL certificate and private key to a list of Dell iDRAC controllers using `racadm` |
| `xMove-VM.ps1` | Performs a cross-vCenter vMotion (xVC-vMotion) between vCenter Servers in the same or different SSO domains, including VMware Cloud on AWS. Community script by William Lam |

### Virtual Machines

| Script | Description |
|--------|-------------|
| `Change-SCSIControllerBusSharing.ps1` | Changes the SCSI Bus Sharing mode to Physical, required for Microsoft Cluster (MSCS) VMs using RDMs |
| `Change-VirtualHardware.ps1` | Upgrades the virtual hardware version of a VM to vmx-11, required for MSCS cluster configurations |
| `Remove-Reservations.ps1` | Removes all CPU and memory reservations from VMs in customer-specific resource pools |

---

## 🛠️ Management (`scripts/management/`)

| Script | Description |
|--------|-------------|
| `Copy-File2VM.ps1` | Copies a local file into a VMware guest VM via the VMware Tools Guest File I/O API (no network required). Opens a file picker dialog at runtime |
| `FoundationCoreAndTiBUsage.psm1` | Retrieves CPU core and TiB storage usage for VCF/VVF deployments. Supports CSV export. Community module by William Lam (Broadcom) |
| `RVToolsBatchMultipleVCs.ps1` | Runs RVTools export-to-XLSX for multiple vCenter servers, merges the output into a single Excel file, and emails it. Community script by Dell Technologies |
| `Send-PasswordExpiryEmail.ps1` | Queries Active Directory for users with expiring passwords and sends automated email reminders. Logs results to CSV |
| `VCSA.psm1` | Functions to retrieve and configure VCSA SSO and local OS password policies via VM guest script execution. Community module by William Lam |

### VCF (`scripts/management/vcf/`)

| Script | Description |
|--------|-------------|
| `AriaOpsAPI.ps1` | Authenticates to VMware Aria Operations via REST API and demonstrates chargeback bill generation |
| `AriaOpsAPIv2.ps1` | Cleaner/updated version of AriaOpsAPI.ps1 with improved code structure |
| `Delete-PendingTasks.ps1` | Cleans up failed/stuck tasks in VMware SDDC Manager using the PowerVCF module. Community script by Brian O'Connell (VMware) |

---

## 🌐 Networking (`scripts/networking/`)

| Script | Description |
|--------|-------------|
| `Export-NSXSegments.ps1` | Exports NSX segments, custom segment profiles, and profile bindings to a JSON + CSV file pair. Interactive menu for segment selection. Supports NSX 4.x and 9.x |
| `Import-NSXSegments.ps1` | Imports NSX segments, profiles, and bindings from the files produced by `Export-NSXSegments.ps1`. Supports renaming via the CSV mapping file |
| `Manage-VDSPortGroups.ps1` | Manages VMware VDS port groups interactively: Export to ZIP, Import with optional renaming, or Delete with confirmation |
| `Remove-NSXSegments.ps1` | Interactively selects and permanently deletes NSX segments and/or custom segment profiles. Includes confirmation prompt and `-WhatIf` support |

### NSX Migration Toolkit (`scripts/networking/nsx migration toolkit/`)

A complete toolkit for migrating NSX Distributed Firewall (DFW) configuration from **NSX 4.x to NSX 9.x**.

**Typical workflow:**

```
Export-NSX-DFW.ps1          → export DFW objects to CSV
Export-NSX-SystemObjects.ps1 → export system object modifications
Sanitize-NSX.ps1            → normalize object IDs (orchestrates steps below)
  ├── Sanitize-NSXGroups.ps1
  ├── Sanitize-NSXServices.ps1
  └── Sanitize-NSXFirewallRules.ps1
Import-NSX-DFW.ps1          → import into NSX 9
Import-NSX-SystemObjects.ps1 → re-apply system object modifications
Compare-NSX-Migration.ps1   → validate the migration
```

| Script | Description |
|--------|-------------|
| `Export-NSX-DFW.ps1` | **Step 1** — Exports IP Sets, Services, Service Groups, Security Groups, Context Profiles, DFW Policies, and Rules from NSX 4 to CSV files |
| `Import-NSX-DFW.ps1` | **Step 2** — Imports DFW objects from the export CSVs into NSX 9 via the Policy REST API, respecting dependency order |
| `Export-NSX-SystemObjects.ps1` | Exports user-modified tags and descriptions from NSX system-owned Services and Groups |
| `Import-NSX-SystemObjects.ps1` | Re-applies exported system object modifications (tags, descriptions) on the destination NSX 9 Manager |
| `Remove-NSX-ImportedObjects.ps1` | Rolls back a migration by deleting all objects imported by `Import-NSX-DFW.ps1`, in reverse dependency order |
| `Remove-NSX-AllCustomObjects.ps1` | Removes all custom DFW objects directly from the NSX Manager inventory (no CSV needed). All object types are opt-in with `-WhatIf` support |
| `Compare-NSX-Migration.ps1` | Validates a migration by live side-by-side comparison of DFW objects between source and destination NSX Managers |
| `Compare-NSX-Migration.v2.ps1` | Alternative validator: reads source CSVs, applies ID mappings, and compares expected vs actual JSON payloads on the destination |
| `Sanitize-NSX.ps1` | Orchestrator: runs the full sanitization pipeline to rename object IDs to match their DisplayNames across all export CSVs |
| `Sanitize-NSXGroups.ps1` | Renames security group IDs to match DisplayNames and updates all cross-references. Includes a tag safety check to protect dynamic group membership |
| `Sanitize-NSXServices.ps1` | Renames service/service group IDs to match DisplayNames and updates all ServiceGroup member path references |
| `Sanitize-NSXFirewallRules.ps1` | Updates group and service ID references in DFW rule and policy CSVs after the sanitization pipeline renames them |
| `Get-NSXTagsInUse.ps1` | Shared helper: discovers which NSX tag scope:value pairs are actively used in security group membership expressions, to prevent sanitization from breaking dynamic membership |

---

## 🏠 Personal (`scripts/personal/`)

Scripts for home energy monitoring.

| Script | Description |
|--------|-------------|
| `Test-GoodWeLogin.ps1` | Tests the GoodWe SEMSPlus login flow using all four authentication methods used by the Energie Dashboard app. Displays the token and API base URL on success |
| `Test-GoodWeSEMS.ps1` | Tests the GoodWe SEMS / SEMSPlus API connection and optionally queries a specific solar plant by Station ID |
| `Test-TibberAPI.ps1` | Tests the Tibber GraphQL API for electricity consumption and solar production data, with optional year filtering |

---

## 📱 Apps (`apps/`)

### ⚡ Energie Dashboard

A local Docker-based web application for tracking monthly electricity consumption, solar panel production, and energy costs.

**Features:**
- Live solar production data from a GoodWe inverter
- KPI cards: total consumption, production, grid export, and costs
- Charts: consumption vs. production, monthly costs, grid export
- Monthly data entry and year-over-year comparison

**Requirements:** [Docker Desktop](https://www.docker.com/products/docker-desktop/)

**Quick start:**
```bash
cd apps/energie-dashboard
docker compose up -d --build
# Open http://localhost:8080
```

See [`apps/energie-dashboard/README.md`](apps/energie-dashboard/README.md) for full documentation.

### 💰 ETF Tracker

A local Docker-based web application for tracking an ETF portfolio.

**Features:**
- Import CSV portfolio data
- Add manual payments
- Charts: Return for current year and for multiple years

**Requirements:** [Docker Desktop](https://www.docker.com/products/docker-desktop/)

**Quick start:**
```bash
cd apps/etf-tracker
docker compose up -d --build
# Open http://localhost:8181
```

See [`apps/etf-tracker/README.md`](apps/etf-tracker/README.md) for full documentation.

### 💰 Money Tracker

A local Docker-based web application for tracking personal expenses and income.

**Features:**
- Import XML CAMT.053 data
- Add manual payments
- Charts: Expenses and Income per category

**Requirements:** [Docker Desktop](https://www.docker.com/products/docker-desktop/)

**Quick start:**
```bash
cd apps/money-tracker
docker compose up -d --build
# Open http://localhost:8282
```

See [`apps/money-tracker/README.md`](apps/money-tracker/README.md) for full documentation.

---

## Prerequisites

- **PowerShell** 7.0 or later — [Download](https://github.com/PowerShell/PowerShell/releases)
- **VMware PowerCLI** — required for all vSphere/NSX scripts
- **ImportExcel** module — required for `Convert-CSV-to-XLSX.ps1` and `RVToolsBatchMultipleVCs.ps1`
- **PowerVCF** module — required for `Delete-PendingTasks.ps1`
- Appropriate permissions for the target systems

> Always review a script before running it in your environment.

Copying file to container: docker cp <file> <container>:<path>
---

## License

This project is licensed under the [MIT License](LICENSE).
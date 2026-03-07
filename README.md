# PowerShell Scripts

A personal collection of PowerShell scripts for DevOps and infrastructure automation. Feel free to use anything here in your own environment.

---

## Prerequisites

- **PowerShell** 7.0 or later ([Download](https://github.com/PowerShell/PowerShell/releases))
- Some scripts may require specific modules — check the comment header at the top of each file
- Appropriate permissions for whatever system you're targeting

> Always review a script before running it in your environment.

---

## Repository Structure

```
root/
├── scripts/
│   ├── backup/          # Backup and restore
│   ├── deploy/          # Deployment automation
│   ├── networking/      # Networking automation
│   ├── monitoring/      # Health checks and alerting
│   └── provisioning/    # Environment setup
└── lib/                 # Shared helper functions
```

---

## Scripts

| Script | Description |
|--------|-------------|
| `scripts/deploy/deploy-app.ps1` | Deploys an application to a target environment |
| `scripts/backup/backup-db.ps1` | Backs up a database to a specified location |
| `scripts/monitoring/check-health.ps1` | Checks service health and sends alerts |

Each script has inline documentation. Run `Get-Help .\scripts\<script-name>.ps1 -Full` for usage details.

---

## Usage

Clone the repo and run whichever script you need:

```powershell
git clone https://github.com/jeroenburen/scripts.git
cd jeroenburen

.\scripts\deploy\deploy-app.ps1 -Environment "staging" -Version "1.2.3"
```

---

## License

This project is licensed under the [MIT License](LICENSE) — use it however you like.

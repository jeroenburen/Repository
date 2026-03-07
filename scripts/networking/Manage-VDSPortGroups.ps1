<#
.SYNOPSIS
    Manage VMware VDS Port Groups interactively - export, import, or delete.

.DESCRIPTION
    Connects to a vCenter server and presents interactive menus to select
    a VDS switch and port groups to act on. Supports three modes:

      Export  - Export selected port groups to zip files in the backup directory.
      Import  - Import selected zip files to a chosen switch, with optional renaming.
      Delete  - Delete selected port groups from a chosen switch (with confirmation).

    All activity is written to both the console and a timestamped log file.

.PARAMETER vCenterServer
    FQDN or IP of the vCenter server to connect to.

.PARAMETER BackupDirectory
    Directory used to store exported zip files (Export mode) or read them from (Import mode).

.PARAMETER Mode
    The operation to perform: Export, Import, or Delete. This parameter is mandatory.

.PARAMETER LogDirectory
    Directory to write log files to. Defaults to a "Logs" subfolder inside BackupDirectory.

.PARAMETER CredentialPath
    Path to a saved encrypted credential file. Defaults to ~\.vcenter_cred.xml.
    Use -SaveCredential on first run to create this file.

.PARAMETER SaveCredential
    Prompts for credentials, saves them encrypted to CredentialPath, then exits.
    Run this once before first use.

.PARAMETER NamePrefix
    Optional prefix to prepend to imported port group names (Import mode only).
    e.g. -NamePrefix "NEW-" renames "HB-VLAN100-PRD" to "NEW-HB-VLAN100-PRD".

.PARAMETER NameSuffix
    Optional suffix to append to imported port group names (Import mode only).
    e.g. -NameSuffix "-v2" renames "HB-VLAN100-PRD" to "HB-VLAN100-PRD-v2".

.EXAMPLE
    # Save credentials once before first use
    .\Manage-VDSPortGroups.ps1 -vCenterServer "vcenter.corp.com" -BackupDirectory "C:\Backups\VDS" -SaveCredential

.EXAMPLE
    # Export selected port groups
    .\Manage-VDSPortGroups.ps1 -vCenterServer "vcenter.corp.com" -BackupDirectory "C:\Backups\VDS" -Mode Export

.EXAMPLE
    # Import selected port groups
    .\Manage-VDSPortGroups.ps1 -vCenterServer "vcenter.corp.com" -BackupDirectory "C:\Backups\VDS" -Mode Import

.EXAMPLE
    # Import and rename port groups with a prefix and suffix
    .\Manage-VDSPortGroups.ps1 -vCenterServer "vcenter.corp.com" -BackupDirectory "C:\Backups\VDS" -Mode Import -NamePrefix "NEW-" -NameSuffix "-v2"

.EXAMPLE
    # Delete selected port groups
    .\Manage-VDSPortGroups.ps1 -vCenterServer "vcenter.corp.com" -BackupDirectory "C:\Backups\VDS" -Mode Delete

.EXAMPLE
    # Use a custom log directory
    .\Manage-VDSPortGroups.ps1 -vCenterServer "vcenter.corp.com" -BackupDirectory "C:\Backups\VDS" -Mode Export -LogDirectory "C:\Logs"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $true)]
    [string]$BackupDirectory,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Export", "Import", "Delete")]
    [string]$Mode = "",

    [Parameter(Mandatory = $false)]
    [string]$LogDirectory = "",

    [Parameter(Mandatory = $false)]
    [string]$CredentialPath = "$env:USERPROFILE\.vcenter_cred.xml",

    [Parameter(Mandatory = $false)]
    [switch]$SaveCredential,

    [Parameter(Mandatory = $false)]
    [string]$NamePrefix = "",

    [Parameter(Mandatory = $false)]
    [string]$NameSuffix = ""
)

# ---------------------------------------------------------------
# MENU FUNCTIONS
# ---------------------------------------------------------------
function Select-MultipleItems {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title
    )
    if ($Items.Count -eq 0) {
        Write-Host "No items available to select." -ForegroundColor Yellow
        return @()
    }
    Write-Host "`n  $Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  [{0,3}]  {1}" -f ($i + 1), $Items[$i].$DisplayProperty)
    }
    Write-Host "`n  Enter numbers (e.g. 1,3,5), a range (e.g. 2-6), a combination (e.g. 1,3-5,8)," -ForegroundColor Gray
    Write-Host "  'all' to select everything, or 'cancel' to abort.`n" -ForegroundColor Gray
    while ($true) {
        $userInput = (Read-Host "  Your selection").Trim()
        if ($userInput -eq 'cancel') {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return @()
        }
        if ($userInput -eq 'all') {
            Write-Host "Selected all $($Items.Count) item(s)." -ForegroundColor Green
            return $Items
        }
        $selectedIndices = @()
        $parts           = $userInput -split ','
        $parseError      = $false
        foreach ($part in $parts) {
            $part = $part.Trim()
            if ($part -match '^\d+$') {
                $selectedIndices += [int]$part
            }
            elseif ($part -match '^(\d+)-(\d+)$') {
                $start = [int]$Matches[1]
                $end   = [int]$Matches[2]
                if ($start -gt $end) {
                    Write-Host "  Invalid range: $part (start must be equal to or less than end)." -ForegroundColor Red
                    $parseError = $true
                    break
                }
                $selectedIndices += $start..$end
            }
            else {
                Write-Host "  Unrecognised input: '$part'. Use numbers, ranges like 2-5, or 'all'." -ForegroundColor Red
                $parseError = $true
                break
            }
        }
        if ($parseError) { continue }
        $selectedIndices = $selectedIndices | Sort-Object -Unique
        $invalid         = $selectedIndices | Where-Object { $_ -lt 1 -or $_ -gt $Items.Count }
        if ($invalid) {
            Write-Host "  Out-of-range: $($invalid -join ', '). Valid range is 1-$($Items.Count)." -ForegroundColor Red
            continue
        }
        $selected = $selectedIndices | ForEach-Object { $Items[$_ - 1] }
        Write-Host "`n  Selected $($selected.Count) item(s):" -ForegroundColor Green
        $selected | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
        Write-Host ""
        return $selected
    }
}

function Select-SingleItem {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title
    )
    if ($Items.Count -eq 0) {
        Write-Host "No items available to select." -ForegroundColor Yellow
        return $null
    }
    Write-Host "`n  $Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  [{0,3}]  {1}" -f ($i + 1), $Items[$i].$DisplayProperty)
    }
    Write-Host "`n  Enter a number to select one item, or 'cancel' to abort.`n" -ForegroundColor Gray
    while ($true) {
        $userInput = (Read-Host "  Your selection").Trim()
        if ($userInput -eq 'cancel') {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return $null
        }
        if ($userInput -match '^\d+$') {
            $index = [int]$userInput
            if ($index -ge 1 -and $index -le $Items.Count) {
                $selected = $Items[$index - 1]
                Write-Host "`n  Selected: $($selected.$DisplayProperty)`n" -ForegroundColor Green
                return $selected
            }
        }
        Write-Host "  Invalid selection. Enter a number between 1 and $($Items.Count)." -ForegroundColor Red
    }
}

# ---------------------------------------------------------------
# VALIDATE MODE
# ---------------------------------------------------------------
if (-not $SaveCredential -and -not $Mode) {
    Write-Error "Parameter -Mode is required. Valid values: Export, Import, Delete."
    exit 1
}

if (($NamePrefix -or $NameSuffix) -and $Mode -ne "Import") {
    Write-Warning "-NamePrefix and -NameSuffix are only applied in Import mode and will be ignored."
}

# ---------------------------------------------------------------
# LOGGING SETUP
# ---------------------------------------------------------------
if (-not $LogDirectory) {
    $LogDirectory = Join-Path $BackupDirectory "Logs"
}

if (-not (Test-Path -Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFile   = Join-Path $LogDirectory "vds_portgroup_${Mode}_${timestamp}.log"

# ---------------------------------------------------------------
# WRITE-LOG FUNCTION
# ---------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    switch ($Level) {
        "SUCCESS" { Write-Host $entry -ForegroundColor Green  }
        "WARNING" { Write-Host $entry -ForegroundColor Yellow }
        "ERROR"   { Write-Host $entry -ForegroundColor Red    }
        default   { Write-Host $entry -ForegroundColor Cyan   }
    }
}

# ---------------------------------------------------------------
# CREDENTIAL FUNCTIONS
# ---------------------------------------------------------------
function Save-VCenterCredential {
    param([string]$Path)
    Write-Host "`nEnter credentials to save for vCenter access:" -ForegroundColor Cyan
    $cred = Get-Credential -Message "Enter vCenter credentials"
    if (-not $cred) {
        Write-Host "No credentials provided. Aborting." -ForegroundColor Red
        exit 1
    }
    $credDir = Split-Path $Path -Parent
    if ($credDir -and -not (Test-Path $credDir)) {
        New-Item -ItemType Directory -Path $credDir -Force | Out-Null
    }
    $cred | Export-Clixml -Path $Path
    Write-Host "Credentials saved securely to: $Path" -ForegroundColor Green
    Write-Host "Re-run without -SaveCredential to use them.`n" -ForegroundColor Cyan
    exit 0
}

function Get-VCenterCredential {
    param([string]$Path)
    if (Test-Path $Path) {
        Write-Host "Loading saved credentials from: $Path" -ForegroundColor Cyan
        return Import-Clixml -Path $Path
    }
    else {
        Write-Host "No saved credential file found at '$Path'." -ForegroundColor Yellow
        Write-Host "Tip: run with -SaveCredential to save credentials for future runs." -ForegroundColor Yellow
        Write-Host "Prompting for credentials now...`n" -ForegroundColor Cyan
        return Get-Credential -Message "Enter vCenter credentials for $vCenterServer"
    }
}

if ($SaveCredential) {
    Save-VCenterCredential -Path $CredentialPath
}

$credential = Get-VCenterCredential -Path $CredentialPath
if (-not $credential) {
    Write-Error "No credentials available. Cannot continue."
    exit 1
}

# ---------------------------------------------------------------
# VCENTER HELPER FUNCTIONS
# ---------------------------------------------------------------
function Get-VDSwitches {
    try {
        $switches = Get-VDSwitch -ErrorAction Stop | Sort-Object Name
        return $switches
    }
    catch {
        Write-Log "Could not retrieve VDS switches: $_" -Level ERROR
        Disconnect-VIServer -Server $vCenterServer -Confirm:$false
        exit 1
    }
}

function Get-PortGroups {
    param(
        [Parameter(Mandatory = $true)]
        $Switch
    )
    $portGroups = $Switch | Get-VDPortgroup | Where-Object { $_.Name -notlike "*DVUplinks*" } | Sort-Object Name
    Write-Log "Found $($portGroups.Count) port group(s) on switch '$($Switch.Name)' (DVUplinks excluded)."
    return $portGroups
}

# ---------------------------------------------------------------
# START
# ---------------------------------------------------------------
Write-Log "===== VDS Port Group Script Started (Mode: $Mode) ====="
Write-Log "vCenter:          $vCenterServer"
Write-Log "Backup Directory: $BackupDirectory"
Write-Log "Log File:         $LogFile"

# ---------------------------------------------------------------
# CONNECT TO VCENTER
# ---------------------------------------------------------------
Write-Log "Connecting to vCenter: $vCenterServer ..."
try {
    Connect-VIServer -Server $vCenterServer -Credential $credential -ErrorAction Stop | Out-Null
    Write-Log "Connected to vCenter successfully." -Level SUCCESS
}
catch {
    Write-Log "Failed to connect to vCenter '$vCenterServer': $_" -Level ERROR
    exit 1
}

# ---------------------------------------------------------------
# EXPORT MODE
# ---------------------------------------------------------------
if ($Mode -eq "Export") {
    Write-Log "--- EXPORT MODE ---"
    if (-not (Test-Path -Path $BackupDirectory)) {
        Write-Log "Backup directory not found. Creating: $BackupDirectory"
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    }
    $vdSwitch = Select-SingleItem -Items (Get-VDSwitches) -DisplayProperty "Name" -Title "Select VDS Switch to EXPORT from"
    if (-not $vdSwitch) {
        Write-Log "No switch selected. Skipping export." -Level WARNING
    }
    else {
        Write-Log "Selected switch: $($vdSwitch.Name)"
        $portgrps = Select-MultipleItems -Items (Get-PortGroups -Switch $vdSwitch) -DisplayProperty "Name" -Title "Select Port Groups to EXPORT"
        if ($portgrps.Count -eq 0) {
            Write-Log "No port groups selected for export. Skipping." -Level WARNING
        }
        else {
            Write-Log "Exporting $($portgrps.Count) port group(s)..."
            $exportSuccess    = 0
            $exportFail       = 0
            $originalLocation = Get-Location
            Set-Location -Path $BackupDirectory
            foreach ($portgrp in $portgrps) {
                try {
                    Export-VDPortGroup -VDPortGroup $portgrp -ErrorAction Stop
                    $exportedFile = Get-ChildItem -Path $BackupDirectory -Filter "*.zip" |
                        Where-Object { $_.Name -like "$($portgrp.Name)*" } |
                        Sort-Object LastWriteTime -Descending |
                        Select-Object -First 1
                    if ($exportedFile) {
                        $cleanPath = Join-Path $BackupDirectory "$($portgrp.Name).zip"
                        if (Test-Path $cleanPath) { Remove-Item $cleanPath -Force }
                        Rename-Item -Path $exportedFile.FullName -NewName "$($portgrp.Name).zip"
                        Write-Log "Exported: $($portgrp.Name).zip" -Level SUCCESS
                    }
                    else {
                        Write-Log "Exported '$($portgrp.Name)' but could not locate zip to rename." -Level WARNING
                    }
                    $exportSuccess++
                }
                catch {
                    Write-Log "Could not export '$($portgrp.Name)': $_" -Level WARNING
                    $exportFail++
                }
            }
            Set-Location -Path $originalLocation
            Write-Log "Export complete: $exportSuccess succeeded, $exportFail failed."
        }
    }
}

# ---------------------------------------------------------------
# IMPORT MODE
# ---------------------------------------------------------------
if ($Mode -eq "Import") {
    Write-Log "--- IMPORT MODE ---"
    if (-not (Test-Path -Path $BackupDirectory)) {
        Write-Log "Backup directory does not exist: $BackupDirectory" -Level ERROR
        Disconnect-VIServer -Server $vCenterServer -Confirm:$false
        exit 1
    }
    $allZips = Get-ChildItem -Path $BackupDirectory -Filter "*.zip" | Sort-Object Name
    if ($allZips.Count -eq 0) {
        Write-Log "No .zip files found in '$BackupDirectory'. Nothing to import." -Level WARNING
    }
    else {
        Write-Log "Found $($allZips.Count) zip file(s) in backup directory."
        $selectedZips = Select-MultipleItems -Items $allZips -DisplayProperty "Name" -Title "Select Port Group Backups to IMPORT"
        if ($selectedZips.Count -eq 0) {
            Write-Log "No zip files selected for import. Skipping." -Level WARNING
        }
        else {
            $vdSwitch = Select-SingleItem -Items (Get-VDSwitches) -DisplayProperty "Name" -Title "Select VDS Switch to IMPORT to"
            if (-not $vdSwitch) {
                Write-Log "No switch selected. Skipping import." -Level WARNING
            }
            else {
                Write-Log "Selected switch: $($vdSwitch.Name)"
                if ($NamePrefix) { Write-Log "Applying name prefix: '$NamePrefix'" }
                if ($NameSuffix) { Write-Log "Applying name suffix: '$NameSuffix'" }
                if (-not $NamePrefix -and -not $NameSuffix) {
                    Write-Log "No -NamePrefix or -NameSuffix specified. Port groups will keep their original names."
                }
                $importSuccess = 0
                $importFail    = 0
                foreach ($zip in $selectedZips) {
                    try {
                        $originalName = [System.IO.Path]::GetFileNameWithoutExtension($zip.Name)
                        $newName      = "$NamePrefix$originalName$NameSuffix"
                        if ($newName -ne $originalName) {
                            $vdSwitch | New-VDPortgroup -BackupPath $zip.FullName -Name $newName -ErrorAction Stop
                            Write-Log "Imported: '$originalName' -> '$newName'" -Level SUCCESS
                        }
                        else {
                            $vdSwitch | New-VDPortgroup -BackupPath $zip.FullName -ErrorAction Stop
                            Write-Log "Imported: '$originalName'" -Level SUCCESS
                        }
                        $importSuccess++
                    }
                    catch {
                        Write-Log "Could not import '$($zip.Name)': $_" -Level WARNING
                        $importFail++
                    }
                }
                Write-Log "Import complete: $importSuccess succeeded, $importFail failed."
            }
        }
    }
}

# ---------------------------------------------------------------
# DELETE MODE
# ---------------------------------------------------------------
if ($Mode -eq "Delete") {
    Write-Log "--- DELETE MODE ---"
    $vdSwitch = Select-SingleItem -Items (Get-VDSwitches) -DisplayProperty "Name" -Title "Select VDS Switch to DELETE from"
    if (-not $vdSwitch) {
        Write-Log "No switch selected. Skipping delete." -Level WARNING
    }
    else {
        Write-Log "Selected switch: $($vdSwitch.Name)"
        $portgrps = Select-MultipleItems -Items (Get-PortGroups -Switch $vdSwitch) -DisplayProperty "Name" -Title "Select Port Groups to DELETE"
        if ($portgrps.Count -eq 0) {
            Write-Log "No port groups selected for deletion. Skipping." -Level WARNING
        }
        else {
            Write-Host "`n  *** WARNING: You are about to permanently delete $($portgrps.Count) port group(s):" -ForegroundColor Red
            $portgrps | ForEach-Object { Write-Host "    - $($_.Name)" -ForegroundColor Yellow }
            Write-Host ""
            $confirm = (Read-Host "  Type 'YES' to confirm, or anything else to cancel").Trim()
            if ($confirm -ne "YES") {
                Write-Log "Deletion cancelled by user." -Level WARNING
            }
            else {
                Write-Log "User confirmed deletion of $($portgrps.Count) port group(s)."
                $deleteSuccess = 0
                $deleteFail    = 0
                foreach ($portgrp in $portgrps) {
                    try {
                        Remove-VDPortGroup -VDPortGroup $portgrp -Confirm:$false -ErrorAction Stop
                        Write-Log "Deleted: $($portgrp.Name)" -Level SUCCESS
                        $deleteSuccess++
                    }
                    catch {
                        Write-Log "Could not delete '$($portgrp.Name)': $_" -Level WARNING
                        $deleteFail++
                    }
                }
                Write-Log "Delete complete: $deleteSuccess succeeded, $deleteFail failed."
            }
        }
    }
}

# ---------------------------------------------------------------
# DISCONNECT
# ---------------------------------------------------------------
Write-Log "Disconnecting from vCenter..."
Disconnect-VIServer -Server $vCenterServer -Confirm:$false
Write-Log "===== Script Finished =====" -Level SUCCESS

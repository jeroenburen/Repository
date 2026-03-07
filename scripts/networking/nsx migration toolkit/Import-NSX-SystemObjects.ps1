#Requires -Version 5.1
<#
.SYNOPSIS
    Imports user-modifiable fields (tags, description) onto NSX system-owned objects.

.DESCRIPTION
    Reads CSV files produced by Export-NSX-SystemObjects.ps1 and applies the
    exported 'tags' and 'description' values onto the matching system-owned objects
    on the destination NSX 9 Manager.

    System-owned objects already exist on every NSX deployment and cannot be
    created or deleted. This script only updates their user-modifiable fields.

    To update protected system-owned objects, the X-Allow-Overwrite: true header
    is required. The script sends a partial PATCH containing only:
      - tags
      - description

    Reads from:
      - NSX_SystemServices.csv
      - NSX_SystemGroups.csv

.PARAMETER NSXManager
    FQDN or IP of the destination NSX 9 Manager.

.PARAMETER InputFolder
    Folder containing the CSV files produced by Export-NSX-SystemObjects.ps1.

.PARAMETER DomainId
    NSX Policy domain. Default: "default"

.PARAMETER ImportServices
    Import system-owned service modifications. Default: $false — must be explicitly set to $true.

.PARAMETER ImportGroups
    Import system-owned group modifications. Default: $false — must be explicitly set to $true.

.PARAMETER LogFile
    Path to a log file. Required when -LogTarget is 'File' or 'Both'.

.PARAMETER LogTarget
    Controls where log output is written.
      Screen : colored output to the console only (default)
      File   : write to -LogFile only, no console output
      Both   : colored console output AND written to -LogFile

.EXAMPLE
    .\Import-NSX-SystemObjects.ps1 -NSXManager nsx9.corp.local -InputFolder .\NSX_SystemObjects_Export_20250101_120000

.EXAMPLE
    .\Import-NSX-SystemObjects.ps1 -NSXManager nsx9.corp.local -InputFolder .\NSX_SystemObjects_Export_20250101_120000 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$NSXManager,
    [Parameter(Mandatory)][string]$InputFolder,
    [string]$DomainId        = 'default',
    [bool]$ImportServices    = $false,
    [bool]$ImportGroups      = $false,
    [string]$LogFile   = '',
    [ValidateSet('Screen','File','Both')]
    [string]$LogTarget = 'Screen'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────
function Write-Log {
    <# Writes a timestamped log line to the screen, a file, or both.
       Controlled by the -LogTarget and -LogFile script parameters.
         Screen : colored output to the console only (default)
         File   : writes to $LogFile only (no console output)
         Both   : colored console output AND appends to $LogFile
    #>
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO'
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[$ts][$Level] $Message"
    $color = switch ($Level) {
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red'    }
        'SUCCESS' { 'Green'  }
        default   { 'Cyan'   }
    }

    if ($LogTarget -eq 'Screen' -or $LogTarget -eq 'Both') {
        Write-Host $line -ForegroundColor $color
    }

    if (($LogTarget -eq 'File' -or $LogTarget -eq 'Both') -and $LogFile) {
        try {
            Add-Content -Path $LogFile -Value $line -Encoding UTF8
        } catch {
            # Fall back to screen if file write fails
            Write-Host "[WARN] Could not write to log file: $_" -ForegroundColor Yellow
            Write-Host $line -ForegroundColor $color
        }
    }
}

# ─────────────────────────────────────────────────────────────
# IGNORE SELF-SIGNED CERTIFICATES
# ─────────────────────────────────────────────────────────────
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
}
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
[System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12

# ─────────────────────────────────────────────────────────────
# CREDENTIALS
# ─────────────────────────────────────────────────────────────
Write-Log "Enter credentials for destination NSX Manager: $NSXManager"
$Cred    = Get-Credential -Message "NSX 9 ($NSXManager) credentials"
$pair    = "$($Cred.UserName):$($Cred.GetNetworkCredential().Password)"
$bytes   = [System.Text.Encoding]::ASCII.GetBytes($pair)

# Standard headers (read operations)
$Headers = @{
    Authorization  = "Basic $([Convert]::ToBase64String($bytes))"
    'Content-Type' = 'application/json'
}

# Headers including X-Allow-Overwrite for patching system-owned objects
$OverwriteHeaders = @{
    Authorization      = "Basic $([Convert]::ToBase64String($bytes))"
    'Content-Type'     = 'application/json'
    'X-Allow-Overwrite'= 'true'
}

# ─────────────────────────────────────────────────────────────
# REST HELPERS
# ─────────────────────────────────────────────────────────────
function Invoke-NSXGet {
    param([string]$Path)
    $uri = "https://$NSXManager$Path"
    try {
        return Invoke-RestMethod -Uri $uri -Method GET -Headers $Headers
    } catch {
        Write-Log "GET $uri failed: $_" ERROR
        return $null
    }
}

function Invoke-NSXPartialPatch {
    <# Sends a partial PATCH with only the specified fields.
       Uses X-Allow-Overwrite to modify system-owned objects.
       Requires partial patching to be enabled on the NSX Manager, or
       falls back to a full PATCH by merging with the existing object. #>
    param([string]$Path, [hashtable]$Fields)
    $uri = "https://$NSXManager$Path"

    # First fetch the current object so we can merge our changes in
    # (required when partial patch is not enabled system-wide)
    try {
        $current = Invoke-RestMethod -Uri $uri -Method GET -Headers $Headers
    } catch {
        Write-Log "Could not fetch current object at $Path : $_" ERROR
        return $false
    }

    # Apply the fields we want to update onto the current object
    foreach ($key in $Fields.Keys) {
        if ($current.PSObject.Properties[$key]) {
            $current.$key = $Fields[$key]
        } else {
            $current | Add-Member -NotePropertyName $key -NotePropertyValue $Fields[$key] -Force
        }
    }

    # Strip read-only fields before PATCHing
    foreach ($field in @('_create_time','_last_modified_time','_create_user',
                         '_last_modified_user','_revision','_system_owned','_protection')) {
        if ($current.PSObject.Properties[$field]) {
            $current.PSObject.Properties.Remove($field)
        }
    }

    $json = $current | ConvertTo-Json -Depth 20 -Compress
    try {
        Invoke-RestMethod -Uri $uri -Method PATCH -Headers $OverwriteHeaders -Body $json | Out-Null
        return $true
    } catch {
        Write-Log "PATCH $uri failed: $_" ERROR
        return $false
    }
}

function Test-ObjectExists {
    param([string]$Path)
    $uri = "https://$NSXManager$Path"
    try {
        Invoke-RestMethod -Uri $uri -Method GET -Headers $Headers | Out-Null
        return $true
    } catch { return $false }
}

# ─────────────────────────────────────────────────────────────
# CSV HELPER
# ─────────────────────────────────────────────────────────────
function Read-CsvFile {
    param([string]$FileName)
    $path = Join-Path $InputFolder $FileName
    if (-not (Test-Path $path)) {
        Write-Log "CSV not found, skipping: $path" WARN
        return @()
    }
    $rows = Import-Csv -Path $path -Encoding UTF8
    Write-Log "  Loaded $(@($rows).Count) rows from $FileName" INFO
    return $rows
}

# ─────────────────────────────────────────────────────────────
# STATISTICS
# ─────────────────────────────────────────────────────────────
$Stats = @{ Services=0; Groups=0; NotFound=0; Errors=0 }

# ═════════════════════════════════════════════════════════════
# 1. IMPORT SYSTEM SERVICE MODIFICATIONS
# ═════════════════════════════════════════════════════════════
function Import-SystemServices {
    Write-Log "━━━ Importing System Service Modifications ━━━" INFO
    $rows = Read-CsvFile 'NSX_SystemServices.csv'
    if (-not $rows) { return }

    foreach ($row in $rows) {
        $id   = $row.Id
        $path = "/policy/api/v1/infra/services/$id"

        # System objects always exist on the destination — but verify just in case
        if (-not (Test-ObjectExists -Path $path)) {
            Write-Log "  NOT FOUND: Service '$id' does not exist on destination (different NSX version?)" WARN
            $Stats.NotFound++
            continue
        }

        # Parse TagsJson back into an object array
        $tags = @()
        try {
            if ($row.TagsJson -and $row.TagsJson -ne '[]') {
                $tags = $row.TagsJson | ConvertFrom-Json
            }
        } catch {
            Write-Log "  Could not parse TagsJson for service '$id': $_" WARN
        }

        $fields = @{
            tags        = $tags
            description = $row.Description
        }

        if ($PSCmdlet.ShouldProcess($id, "Update system service tags/description")) {
            $ok = Invoke-NSXPartialPatch -Path $path -Fields $fields
            if ($ok) {
                $Stats.Services++
                $tagStr = if ($row.Tags) { $row.Tags } else { '(no tags)' }
                Write-Log "  ✔ Service: $id ($($row.DisplayName)) — $tagStr" SUCCESS
            } else {
                $Stats.Errors++
            }
        }
    }
}

# ═════════════════════════════════════════════════════════════
# 2. IMPORT SYSTEM GROUP MODIFICATIONS
# ═════════════════════════════════════════════════════════════
function Import-SystemGroups {
    Write-Log "━━━ Importing System Group Modifications ━━━" INFO
    $rows = Read-CsvFile 'NSX_SystemGroups.csv'
    if (-not $rows) { return }

    foreach ($row in $rows) {
        $id   = $row.Id
        $path = "/policy/api/v1/infra/domains/$DomainId/groups/$id"

        if (-not (Test-ObjectExists -Path $path)) {
            Write-Log "  NOT FOUND: Group '$id' does not exist on destination (different NSX version?)" WARN
            $Stats.NotFound++
            continue
        }

        $tags = @()
        try {
            if ($row.TagsJson -and $row.TagsJson -ne '[]') {
                $tags = $row.TagsJson | ConvertFrom-Json
            }
        } catch {
            Write-Log "  Could not parse TagsJson for group '$id': $_" WARN
        }

        $fields = @{
            tags        = $tags
            description = $row.Description
        }

        if ($PSCmdlet.ShouldProcess($id, "Update system group tags/description")) {
            $ok = Invoke-NSXPartialPatch -Path $path -Fields $fields
            if ($ok) {
                $Stats.Groups++
                $tagStr = if ($row.Tags) { $row.Tags } else { '(no tags)' }
                Write-Log "  ✔ Group: $id ($($row.DisplayName)) — $tagStr" SUCCESS
            } else {
                $Stats.Errors++
            }
        }
    }
}

# ═════════════════════════════════════════════════════════════
# VALIDATE INPUT FOLDER
# ═════════════════════════════════════════════════════════════
if (-not (Test-Path $InputFolder)) {
    Write-Log "Input folder not found: $InputFolder" ERROR
    exit 1
}
$InputFolder = (Resolve-Path $InputFolder).Path

# ═════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════
# Guard — refuse to run if no import flags are set
$anyAction = $ImportServices -or $ImportGroups

if (-not $anyAction) {
    Write-Log "No import actions selected. Specify at least one -Import* flag." WARN
    Write-Log "Example: -ImportServices `$true -ImportGroups `$true" WARN
    exit 0
}

Write-Log "════════════════════════════════════════════" INFO
Write-Log " NSX SYSTEM OBJECTS IMPORT" INFO
Write-Log " Destination  : $NSXManager" INFO
Write-Log " Input folder : $InputFolder" INFO
Write-Log " Domain       : $DomainId" INFO
Write-Log "════════════════════════════════════════════" INFO
Write-Log " NOTE: Only 'tags' and 'description' are updated." WARN
Write-Log "       Core definitions of system objects are immutable." WARN
Write-Log "════════════════════════════════════════════" INFO

try {
    Write-Log "Verifying connectivity to $NSXManager..." INFO
    $info = Invoke-NSXGet -Path "/api/v1/node"
    if ($info) { Write-Log "  Connected: NSX $($info.product_version)" SUCCESS }
    else        { throw "Cannot connect to NSX Manager $NSXManager." }

    if ($ImportServices) { Import-SystemServices }
    if ($ImportGroups)   { Import-SystemGroups   }

} catch {
    Write-Log "FATAL: $_" ERROR
    exit 1
} finally {
    Write-Log "════════════════════════════════════════════" INFO
    Write-Log " IMPORT SUMMARY" INFO
    Write-Log "────────────────────────────────────────────" INFO
    Write-Log "  System Services updated  : $($Stats.Services)"  INFO
    Write-Log "  System Groups updated    : $($Stats.Groups)"    INFO
    Write-Log "  Not found on destination : $($Stats.NotFound)"  WARN
    Write-Log "  Errors                   : $($Stats.Errors)"    $(if ($Stats.Errors -gt 0) { 'ERROR' } else { 'INFO' })
    Write-Log "════════════════════════════════════════════" INFO


}

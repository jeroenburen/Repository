#Requires -Version 5.1
<#
.SYNOPSIS
    Exports user-modifiable fields from NSX system-owned Services and Groups to CSV.

.DESCRIPTION
    System-owned objects (built-in NSX services like HTTPS, DNS, and default groups)
    cannot be created or deleted, but their 'tags' and 'description' fields can be
    modified by users. This script exports those fields so they can be re-applied on
    a destination NSX 9 Manager using Import-NSX-SystemObjects.ps1.

    Exports to:
      - NSX_SystemServices.csv   — system-owned services with user-modified fields
      - NSX_SystemGroups.csv     — system-owned groups with user-modified fields

    Only objects where 'tags' or 'description' differ from a blank/default state
    are exported, since unmodified system objects need no action on the destination.

.PARAMETER NSXManager
    FQDN or IP of the source NSX 4 Manager.

.PARAMETER OutputFolder
    Folder where CSV files will be written. Created if it doesn't exist.
    Default: .\NSX_SystemObjects_Export_<timestamp>

.PARAMETER DomainId
    NSX Policy domain. Default: "default"

.PARAMETER ExportServices
    Export system-owned Services. Default: $true

.PARAMETER ExportGroups
    Export system-owned Groups. Default: $true

.PARAMETER OnlyModified
    When $true (default), only export objects that have tags or a non-empty description,
    since unmodified system objects require no action on the destination.
    Set to $false to export ALL system-owned objects regardless.

.PARAMETER LogFile
    Optional path for a transcript log file.

.EXAMPLE
    .\Export-NSX-SystemObjects.ps1 -NSXManager nsx4.corp.local

.EXAMPLE
    .\Export-NSX-SystemObjects.ps1 -NSXManager nsx4.corp.local -OnlyModified $false
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$NSXManager,
    [string]$OutputFolder  = ".\NSX_SystemObjects_Export_$(Get-Date -Format 'yyyyMMdd_HHmmss')",
    [string]$DomainId      = 'default',
    [bool]$ExportServices  = $true,
    [bool]$ExportGroups    = $true,
    [bool]$OnlyModified    = $true,
    [string]$LogFile       = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────
if ($LogFile) { Start-Transcript -Path $LogFile -Append }

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','SUCCESS')]$Level = 'INFO')
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red'    }
        'SUCCESS' { 'Green'  }
        default   { 'Cyan'   }
    }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
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
Write-Log "Enter credentials for NSX Manager: $NSXManager"
$Cred    = Get-Credential -Message "NSX 4 ($NSXManager) credentials"
$pair    = "$($Cred.UserName):$($Cred.GetNetworkCredential().Password)"
$bytes   = [System.Text.Encoding]::ASCII.GetBytes($pair)
$Headers = @{
    Authorization  = "Basic $([Convert]::ToBase64String($bytes))"
    'Content-Type' = 'application/json'
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

function Get-AllPages {
    param([string]$Path)
    $allResults = @()
    $cursor     = $null
    do {
        $url  = if ($cursor) { "${Path}?cursor=$cursor" } else { $Path }
        $resp = Invoke-NSXGet -Path $url
        if ($null -eq $resp) { break }
        if ($resp.PSObject.Properties['results'] -and $resp.results) { $allResults += $resp.results }
        $cursor = if ($resp.PSObject.Properties['cursor']) { $resp.cursor } else { $null }
    } while ($cursor)
    return $allResults
}

function Get-SafeProp {
    param([object]$Obj, [string]$Name)
    if ($Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    return $null
}

function Format-Tags {
    param([object]$Obj)
    $tags = Get-SafeProp $Obj 'tags'
    if ($tags) { return ($tags | ForEach-Object { "$($_.scope):$($_.tag)" }) -join '; ' }
    return ''
}

function Has-UserModifications {
    # Returns $true if the object has any tags or a non-empty description
    param([object]$Obj)
    $tags = Get-SafeProp $Obj 'tags'
    $desc = Get-SafeProp $Obj 'description'
    return ($tags -and @($tags).Count -gt 0) -or ($desc -and $desc.Trim() -ne '')
}

# ─────────────────────────────────────────────────────────────
# OUTPUT FOLDER
# ─────────────────────────────────────────────────────────────
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder | Out-Null
    Write-Log "Created output folder: $OutputFolder" INFO
}
$OutputFolder = (Resolve-Path $OutputFolder).Path

$Stats = @{ Services=0; Groups=0; Skipped=0 }

# ═════════════════════════════════════════════════════════════
# 1. EXPORT SYSTEM-OWNED SERVICES
# ═════════════════════════════════════════════════════════════
function Export-SystemServices {
    Write-Log "━━━ Exporting System-Owned Services ━━━" INFO
    $all    = Get-AllPages -Path "/policy/api/v1/infra/services"
    $system = $all | Where-Object { (Get-SafeProp $_ '_system_owned') -eq $true }

    if (-not $system) { Write-Log "No system-owned Services found." WARN; return }
    Write-Log "  Found $(@($system).Count) system-owned services total." INFO

    $rows = foreach ($svc in $system) {
        if ($OnlyModified -and -not (Has-UserModifications $svc)) {
            $Stats.Skipped++
            continue
        }

        [PSCustomObject]@{
            ObjectType   = 'SystemService'
            Id           = $svc.id
            DisplayName  = $svc.display_name
            Description  = (Get-SafeProp $svc 'description')
            Tags         = (Format-Tags $svc)
            # Store tags as JSON for reliable round-trip on import
            TagsJson     = if ((Get-SafeProp $svc 'tags')) {
                               $svc.tags | ConvertTo-Json -Depth 5 -Compress
                           } else { '[]' }
        }
    }

    if (-not $rows) {
        Write-Log "  No system services with user modifications found." WARN
        return
    }

    $csvPath = Join-Path $OutputFolder 'NSX_SystemServices.csv'
    @($rows) | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    $Stats.Services = @($rows).Count
    Write-Log "  Exported $($Stats.Services) system services → $csvPath" SUCCESS
    if ($OnlyModified) {
        Write-Log "  ($($Stats.Skipped) unmodified system services skipped)" INFO
    }
}

# ═════════════════════════════════════════════════════════════
# 2. EXPORT SYSTEM-OWNED GROUPS
# ═════════════════════════════════════════════════════════════
function Export-SystemGroups {
    Write-Log "━━━ Exporting System-Owned Groups ━━━" INFO
    $all    = Get-AllPages -Path "/policy/api/v1/infra/domains/$DomainId/groups"
    $system = $all | Where-Object { (Get-SafeProp $_ '_system_owned') -eq $true }

    if (-not $system) { Write-Log "No system-owned Groups found." WARN; return }
    Write-Log "  Found $(@($system).Count) system-owned groups total." INFO

    $rows = foreach ($grp in $system) {
        if ($OnlyModified -and -not (Has-UserModifications $grp)) {
            $Stats.Skipped++
            continue
        }

        [PSCustomObject]@{
            ObjectType  = 'SystemGroup'
            Id          = $grp.id
            DisplayName = $grp.display_name
            Description = (Get-SafeProp $grp 'description')
            Tags        = (Format-Tags $grp)
            TagsJson    = if ((Get-SafeProp $grp 'tags')) {
                              $grp.tags | ConvertTo-Json -Depth 5 -Compress
                          } else { '[]' }
        }
    }

    if (-not $rows) {
        Write-Log "  No system groups with user modifications found." WARN
        return
    }

    $csvPath = Join-Path $OutputFolder 'NSX_SystemGroups.csv'
    @($rows) | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    $Stats.Groups = @($rows).Count
    Write-Log "  Exported $($Stats.Groups) system groups → $csvPath" SUCCESS
    if ($OnlyModified) {
        Write-Log "  ($($Stats.Skipped) unmodified system groups skipped)" INFO
    }
}

# ═════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════
Write-Log "════════════════════════════════════════════" INFO
Write-Log " NSX SYSTEM OBJECTS EXPORT" INFO
Write-Log " Source       : $NSXManager" INFO
Write-Log " Output       : $OutputFolder" INFO
Write-Log " Domain       : $DomainId" INFO
Write-Log " Only Modified: $OnlyModified" INFO
Write-Log "════════════════════════════════════════════" INFO

try {
    Write-Log "Verifying connectivity to $NSXManager..." INFO
    $info = Invoke-NSXGet -Path "/api/v1/node"
    if ($info) { Write-Log "  Connected: NSX $($info.product_version)" SUCCESS }
    else        { throw "Cannot connect to NSX Manager $NSXManager." }

    if ($ExportServices) { Export-SystemServices }
    if ($ExportGroups)   { Export-SystemGroups   }

} catch {
    Write-Log "FATAL: $_" ERROR
    exit 1
} finally {
    Write-Log "════════════════════════════════════════════" INFO
    Write-Log " EXPORT SUMMARY" INFO
    Write-Log "────────────────────────────────────────────" INFO
    Write-Log "  System Services exported : $($Stats.Services)" INFO
    Write-Log "  System Groups exported   : $($Stats.Groups)"   INFO
    Write-Log "  Unmodified (skipped)     : $($Stats.Skipped)"  INFO
    Write-Log "────────────────────────────────────────────" INFO
    Write-Log "  Output folder : $OutputFolder" INFO
    Write-Log "════════════════════════════════════════════" INFO
    Write-Log "Review the CSVs, then run:" INFO
    Write-Log "  .\Import-NSX-SystemObjects.ps1 -NSXManager <nsx9> -InputFolder '$OutputFolder'" INFO

    if ($LogFile) { Stop-Transcript }
}

# =============================================================================
# Sanitize-NSXServices.ps1
# Version 1.0.0
#
# PURPOSE
# -------
# In NSX exports, a service's Id (internal identifier) can differ from its
# DisplayName (human-readable label). For example:
#
#   Id: application-228      DisplayName: HTTP-8080
#   Id: application-317      DisplayName: Custom-LDAP-TCP
#   Id: applicationgroup-45  DisplayName: Web-Services-Group
#
# This script renames every Service and ServiceGroup Id to match its
# DisplayName, and updates all service-to-service cross-references inside
# ServiceGroup members so paths remain consistent throughout the export.
#
# WHAT GETS CHANGED
# -----------------
# For each Service or ServiceGroup where Id != DisplayName:
#
#   CSV columns:
#     - Id          ->  set to sanitized DisplayName
#     - DisplayName ->  set to sanitized DisplayName
#     - Tags        ->  kept or cleared per TAG SAFETY CHECK below
#
#   Inside RawJson:
#     - "id":"<oldId>"              ->  "id":"<newId>"
#     - "relative_path":"<oldId>"   ->  "relative_path":"<newId>"
#     - "display_name":"<oldName>"  ->  "display_name":"<newId>"
#     - Any /services/<oldId>/ or /services/<oldId>" path segment
#       (covers ServiceGroup member path references)
#     - "tags":[...]                ->  kept or cleared per TAG SAFETY CHECK
#
# TAG SAFETY CHECK
# ----------------
# Before any tags are removed, this script queries the live NSX Manager API
# to discover which tag scope:value pairs are actively referenced inside
# security group Condition expressions (key = "Tag"). Tags in use are KEPT
# and a WARNING is written. All other tags (migration artefacts) are removed.
#
# Provide -NSXManager (and optionally -Headers) to enable the live check.
# If -NSXManager is omitted the check is skipped and ALL tags are removed.
#
# SERVICEGROUP MEMBER REFERENCES
# -------------------------------
# ServiceGroup "members" arrays contain NSX paths like /infra/services/<id>.
# When a referenced service's Id is renamed those paths become stale. This
# script rewrites all such paths using the same ID mapping table, following
# the same pattern as Sanitize-NSXFirewallRules.ps1 for /groups/ references.
#
# OUTPUTS
# -------
#   <InputFile>_sanitized.csv  — services/service groups CSV with corrected
#                                Ids and RawJson
#   <InputFile>_id_mapping.csv — audit log of every oldId -> newId rename
#                                (only written in standalone mode)
#
# USAGE
# -----
#   # Standalone with tag safety check:
#   .\Sanitize-NSXServices.ps1 -InputFile "NSX_Services.csv" `
#                              -NSXManager "nsx4.corp.local"
#
#   # Standalone without tag check (all tags removed):
#   .\Sanitize-NSXServices.ps1 -InputFile "NSX_Services.csv"
#
#   # Called from an orchestrator — returns the idMap hashtable directly:
#   $serviceIdMap = .\Sanitize-NSXServices.ps1 -InputFile "NSX_Services.csv" `
#                      -NSXManager "nsx4.corp.local" -Headers $Headers -PassThruMap
#
# NOTES
# -----
#   - Process NSX_Services.csv before NSX_ServiceGroups.csv so that the full
#     ID map is available when rewriting ServiceGroup member paths.
#   - This script follows the same conventions as Sanitize-NSXGroups.ps1.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [string]$OutputFile  = ($InputFile -replace '\.csv$', '_sanitized.csv'),
    [string]$MappingFile = ($InputFile -replace '\.csv$', '_id_mapping.csv'),

    # NSX Manager connection — required for the live tag-in-use check.
    [string]   $NSXManager = '',
    [hashtable]$Headers    = @{},
    [string]   $DomainId   = 'default',

    # When set, skips writing the mapping CSV and returns the hashtable.
    [switch]$PassThruMap,

    # Optionally seed the map from a prior pass (e.g. Services -> ServiceGroups).
    [hashtable]$SeedMap = @{}
)

Write-Host "Sanitize-NSXServices.ps1 v1.0.0" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 0. Dot-source the shared tag checker
# ---------------------------------------------------------------------------
$tagCheckerPath = Join-Path $PSScriptRoot 'Get-NSXTagsInUse.ps1'
if (Test-Path $tagCheckerPath) {
    . $tagCheckerPath
} else {
    Write-Warning "Get-NSXTagsInUse.ps1 not found alongside this script — tag safety check will be skipped."
}

# ---------------------------------------------------------------------------
# 1. Resolve NSX credentials if manager specified but no headers passed
# ---------------------------------------------------------------------------
$inUseTags = @{}

if ($NSXManager) {
    if ($Headers.Count -eq 0) {
        Write-Host "  [TagCheck] Enter credentials for NSX Manager: $NSXManager" -ForegroundColor Cyan
        $cred  = Get-Credential -Message "NSX ($NSXManager) credentials for tag check"
        $pair  = "$($cred.UserName):$($cred.GetNetworkCredential().Password)"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
        $Headers = @{
            Authorization  = "Basic $([Convert]::ToBase64String($bytes))"
            'Content-Type' = 'application/json'
        }

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
    }

    if (Get-Command 'Get-NSXTagsInUse' -ErrorAction SilentlyContinue) {
        # Services/ServiceGroups are matched by group Tag conditions just like
        # any other member type — pass the Groups CSV so Phase 1 can scan it
        $groupsCsvPath = Join-Path (Split-Path $InputFile) 'NSX_Groups.csv'
        $inUseTags = Get-NSXTagsInUse -GroupsCsv $groupsCsvPath -NSXManager $NSXManager -Headers $Headers -DomainId $DomainId
    } else {
        Write-Warning "Get-NSXTagsInUse function not available — tag safety check skipped."
    }
} else {
    if (Get-Command 'Get-NSXTagsInUse' -ErrorAction SilentlyContinue) {
        Write-Host "  [TagCheck] -NSXManager not provided — running CSV-only tag check (system-owned groups will not be scanned)." -ForegroundColor Yellow
        $groupsCsvPath = Join-Path (Split-Path $InputFile) 'NSX_Groups.csv'
        $inUseTags = Get-NSXTagsInUse -GroupsCsv $groupsCsvPath
    } else {
        Write-Host "  [TagCheck] Get-NSXTagsInUse not available — tag safety check skipped. ALL tags will be removed." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# 2. Load the services CSV
# ---------------------------------------------------------------------------
Write-Host "  [Services] Reading: $InputFile" -ForegroundColor Cyan
$rows = Import-Csv -Path $InputFile

if (-not $rows -or @($rows).Count -eq 0) {
    Write-Host "  [Services] No rows found in $InputFile — nothing to do." -ForegroundColor Yellow
    if ($PassThruMap) { return @{} } else { return }
}

# ---------------------------------------------------------------------------
# 3. Build the old-ID -> new-ID mapping table
# ---------------------------------------------------------------------------
function Sanitize-Id {
    param([string]$value)
    return [regex]::Replace($value.Trim(), '[^a-zA-Z0-9_-]', '-')
}

# Start from any seed IDs provided by the caller
$idMap = @{}
foreach ($key in $SeedMap.Keys) { $idMap[$key] = $SeedMap[$key] }

# Pass 1 — count occurrences of each sanitized DisplayName
$displayCount = @{}
foreach ($row in $rows) {
    $sanitized = Sanitize-Id $row.DisplayName
    $displayCount[$sanitized] = ($displayCount[$sanitized] -as [int]) + 1
}

# Pass 2 — assign newIds with deduplication suffixes
$displayCounter = @{}
foreach ($row in $rows) {
    $oldId     = $row.Id.Trim()
    $sanitized = Sanitize-Id $row.DisplayName

    if ($displayCount[$sanitized] -gt 1) {
        if (-not $displayCounter.ContainsKey($sanitized)) { $displayCounter[$sanitized] = 1 }
        $suffix = $displayCounter[$sanitized]
        $displayCounter[$sanitized]++
        $newId = "$sanitized-$suffix"
        Write-Warning "Duplicate DisplayName '$sanitized' — assigned '$newId' to Id '$oldId'."
    } else {
        $newId = $sanitized
    }

    if ($oldId -ne $newId) {
        if ($idMap.ContainsKey($oldId)) { Write-Warning "Duplicate old ID '$oldId' — skipping." }
        else                            { $idMap[$oldId] = $newId }
    }
}

$newMappings = $idMap.Count - $SeedMap.Count
Write-Host "  [Services] $newMappings ID(s) need renaming." -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# 4. Helpers
# ---------------------------------------------------------------------------
function Decode-UnicodeEscapes {
    param([string]$text)
    return [regex]::Replace($text, '\\u([0-9a-fA-F]{4})', {
        param($m)
        [char][convert]::ToInt32($m.Groups[1].Value, 16)
    })
}

function Update-ServicePaths {
    param([string]$text)
    $sortedKeys = $idMap.Keys | Sort-Object { $_.Length } -Descending
    foreach ($oldId in $sortedKeys) {
        $escaped = [regex]::Escape($oldId)
        $text = [regex]::Replace($text, "(?<=/services/)$escaped(?=/|""|$)", $idMap[$oldId])
    }
    return $text
}

function Remove-Tags {
    <# Removes tags from a RawJson string, but KEEPS any tag whose scope|value
       or bare value is found in $inUseTags (actively used in group expressions).
       Emits a warning for every tag that is kept. #>
    param([string]$json, [string]$objectId)

    try {
        $obj  = $json | ConvertFrom-Json
        $tags = if ($obj.PSObject.Properties['tags']) { @($obj.tags) } else { @() }

        if ($tags.Count -eq 0) { return $json }

        $keep = [System.Collections.Generic.List[object]]::new()

        foreach ($tag in $tags) {
            $scope = if ($tag.PSObject.Properties['scope']) { $tag.scope } else { '' }
            $value = if ($tag.PSObject.Properties['tag']  ) { $tag.tag   } else { '' }

            $keyWithScope = if ($scope) { "$scope|$value" } else { $null }
            $keyBare      = $value

            $usedBy = @()
            if ($keyWithScope -and $inUseTags[$keyWithScope]) { $usedBy += $inUseTags[$keyWithScope] }
            if ($keyBare      -and $inUseTags[$keyBare]      ) { $usedBy += $inUseTags[$keyBare]      }
            $usedBy = $usedBy | Select-Object -Unique

            if ($usedBy.Count -gt 0) {
                $keep.Add($tag)
                Write-Host ("  [TagCheck] WARN: Keeping tag '$scope`:$value' on '$objectId' " +
                            "— referenced by group(s): $($usedBy -join ', ')") -ForegroundColor Yellow
            }
        }

        $obj.tags = $keep.ToArray()
        return ($obj | ConvertTo-Json -Depth 20 -Compress)

    } catch {
        Write-Host "  [TagCheck] Could not parse tags for '$objectId' — using regex fallback: $_" -ForegroundColor Yellow
        return [regex]::Replace($json, '"tags":\[.*?\]', '"tags":[]')
    }
}

# ---------------------------------------------------------------------------
# 5. Apply changes to every row
# ---------------------------------------------------------------------------
$mappingLog = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($row in $rows) {
    $oldId = $row.Id.Trim()

    $row.RawJson = Decode-UnicodeEscapes -text $row.RawJson

    if ($idMap.ContainsKey($oldId)) {
        $newId      = $idMap[$oldId]
        $oldDisplay = $row.DisplayName.Trim()

        $row.Id          = $newId
        $row.DisplayName = $newId

        $json = Update-ServicePaths -text $row.RawJson

        $esc        = [regex]::Escape($oldId)
        $escDisplay = [regex]::Escape($oldDisplay)
        $json = $json -replace """id"":""$esc""",                  """id"":""$newId"""
        $json = $json -replace """relative_path"":""$esc""",       """relative_path"":""$newId"""
        $json = $json -replace """display_name"":""$escDisplay""", """display_name"":""$newId"""

        $json        = Remove-Tags -json $json -objectId $newId
        $row.RawJson = $json

        if (-not $SeedMap.ContainsKey($oldId)) {
            $mappingLog.Add([PSCustomObject]@{ OldId = $oldId; NewId = $newId })
        }
    } else {
        $row.RawJson = Remove-Tags -json (Update-ServicePaths -text $row.RawJson) -objectId $oldId
    }

    # Rebuild the Tags CSV column from surviving tags
    try {
        $obj  = $row.RawJson | ConvertFrom-Json
        $tags = if ($obj.PSObject.Properties['tags']) { @($obj.tags) } else { @() }
        if ($row.PSObject.Properties['Tags']) {
            $row.Tags = if ($tags.Count -gt 0) {
                ($tags | ForEach-Object {
                    $s = if ($_.PSObject.Properties['scope']) { $_.scope } else { '' }
                    $v = if ($_.PSObject.Properties['tag']  ) { $_.tag   } else { '' }
                    "$s`:$v"
                }) -join '; '
            } else { '' }
        }
    } catch {
        if ($row.PSObject.Properties['Tags']) { $row.Tags = '' }
    }
}

# ---------------------------------------------------------------------------
# 6. Write the sanitized services CSV
# ---------------------------------------------------------------------------
Write-Host "  [Services] Writing: $OutputFile" -ForegroundColor Cyan
$rows | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------------
# 7. Return the map or write it to CSV
# ---------------------------------------------------------------------------
if ($PassThruMap) {
    return $idMap
} else {
    Write-Host "  [Services] Writing mapping log: $MappingFile" -ForegroundColor Cyan
    if ($mappingLog.Count -gt 0) {
        $mappingLog | Export-Csv -Path $MappingFile -NoTypeInformation -Encoding UTF8
    } else {
        '"OldId","NewId"' | Set-Content -Path $MappingFile -Encoding UTF8
    }

    Write-Host ""
    Write-Host "Done! $($mappingLog.Count) service(s) renamed." -ForegroundColor Green
    if ($mappingLog.Count -gt 0) { $mappingLog | Format-Table -AutoSize }
}

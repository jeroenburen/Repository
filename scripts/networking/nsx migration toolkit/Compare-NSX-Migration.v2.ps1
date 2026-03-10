#Requires -Version 5.1
<#
.SYNOPSIS
    Validates an NSX DFW migration by comparing source CSV objects against the live destination NSX Manager.

.DESCRIPTION
    Instead of querying both source and destination NSX Managers, this script takes a
    different approach:

      1. Reads source objects from the same CSV files produced by Export-NSX-DFW.ps1
         (and optionally sanitized by Sanitize-NSX.ps1).
      2. Applies the ID mapping files (produced by Sanitize-NSX.ps1) to rewrite object
         IDs and all internal path references — producing the exact JSON payload that
         was (or should have been) imported into the destination.
      3. Fetches each object from the destination NSX Manager by its (mapped) ID.
      4. Strips NSX read-only fields from the destination payload.
      5. Normalizes both JSON strings (sort keys, strip whitespace) and compares them.

    This means the comparison is purely: "does the destination object match what we
    intended to import?" — no field-by-field logic required.

    OBJECT TYPES COMPARED
    ---------------------
      - Services (NSX_Services.csv + NSX_ServiceGroups.csv)
      - Security Groups (NSX_Groups.csv)
      - Context Profiles (NSX_Profiles.csv)
      - DFW Policies (NSX_Policies.csv)
      - DFW Rules (NSX_Rules.csv)

    RESULT CODES PER OBJECT
    -----------------------
      ✔ MATCH        — destination object exists and JSON matches expected
      ⚠ MISMATCH     — destination object exists but JSON differs
      ✗ MISSING_DST  — object not found on destination
      ✗ EXTRA_DST    — object exists on destination but was not in source CSV

    MAPPING FILE SUPPORT
    --------------------
    When Sanitize-NSX.ps1 has been run, supply the mapping CSVs so the script
    can translate source IDs to their renamed counterparts:

        -GroupMappingFile   "NSX_Groups_id_mapping.csv"
        -ServiceMappingFile "NSX_Services_id_mapping.csv"

    Each CSV must contain OldId and NewId columns.
    When not provided, the script assumes IDs were not changed.

    OUTPUT
    ------
    An HTML report and a CSV findings file are written to -OutputFolder.

.PARAMETER DestNSX
    FQDN or IP of the destination NSX Manager.

.PARAMETER DomainId
    NSX Policy domain. Default: "default"

.PARAMETER OutputFolder
    Folder where the HTML report and CSV are written. Created if it does not exist.
    Default: .\NSX_Validation_<timestamp>

.PARAMETER LogFile
    Path for the log file. Defaults to a file inside OutputFolder.

.PARAMETER LogTarget
    Controls where log output is written.
      Screen : colored output to the console only (default)
      File   : write to -LogFile only, no console output
      Both   : colored console output AND written to -LogFile

.PARAMETER CompareServices
    Compare Services and Service Groups. Default: $true

.PARAMETER CompareGroups
    Compare Security Groups. Default: $true

.PARAMETER CompareProfiles
    Compare Context Profiles. Default: $true

.PARAMETER ComparePolicies
    Compare DFW Policies and Rules. Default: $true

.PARAMETER GroupMappingFile
    Path to the groups ID mapping CSV produced by Sanitize-NSX.ps1
    (typically NSX_Groups_id_mapping.csv). Must contain OldId and NewId columns.

.PARAMETER ServiceMappingFile
    Path to the services ID mapping CSV produced by Sanitize-NSX.ps1
    (typically NSX_Services_id_mapping.csv). Must contain OldId and NewId columns.

.EXAMPLE
    .\Compare-NSX-Migration.ps1 -DestNSX nsx9.corp.local

.EXAMPLE
    .\Compare-NSX-Migration.ps1 -DestNSX nsx9.corp.local `
        -GroupMappingFile   .\NSX_DFW_Export\NSX_Groups_id_mapping.csv `
        -ServiceMappingFile .\NSX_DFW_Export\NSX_Services_id_mapping.csv

.EXAMPLE
    .\Compare-NSX-Migration.ps1 -DestNSX nsx9.corp.local `
        -GroupMappingFile   .\NSX_DFW_Export\NSX_Groups_id_mapping.csv `
        -ServiceMappingFile .\NSX_DFW_Export\NSX_Services_id_mapping.csv `
        -OutputFolder C:\Reports\Migration -LogTarget Both

.NOTES
    Version : 2.1.0
    Changelog:
      2.0.0  Complete redesign. Source data is now read from CSV files (same files
             used by Import-NSX-DFW.ps1) instead of querying the source NSX Manager.
             Comparison is performed by normalizing and diffing JSON strings rather
             than field-by-field logic. ID mapping files are used to rewrite source
             IDs and path references to their sanitized equivalents before comparison.
             Added Context Profiles comparison. Removed IP Sets (not in scope).
      2.1.0  Added owner_id to $ReadOnlyFields so it is stripped from destination
             payloads before comparison. Fixed display_name rewrite in the remapping
             blocks for Services and Groups — now mirrors Sanitize-NSXServices.ps1
             and Sanitize-NSXGroups.ps1 by also updating "display_name" inside
             RawJson when the object ID was renamed by the sanitize pipeline.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DestNSX,
    [string]$DomainId     = 'default',
    [string]$OutputFolder = ".\NSX_Validation_$(Get-Date -Format 'yyyyMMdd_HHmmss')",
    [string]$LogFile      = '',
    [ValidateSet('Screen','File','Both')]
    [string]$LogTarget    = 'Screen',
    [bool]$CompareServices = $true,
    [bool]$CompareGroups   = $true,
    [bool]$CompareProfiles = $true,
    [bool]$ComparePolicies = $true,
    [string]$GroupMappingFile   = '',
    [string]$ServiceMappingFile = ''
)

$ScriptVersion = '2.1.0'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────
# OUTPUT FOLDER & LOG FILE
# ─────────────────────────────────────────────────────────────
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}
$OutputFolder = (Resolve-Path $OutputFolder).Path

if (-not $LogFile) {
    $LogFile = Join-Path $OutputFolder "Compare-NSX-Migration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
}

# ─────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────
function Write-Log {
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
        try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 }
        catch { Write-Host "[WARN] Could not write to log file: $_" -ForegroundColor Yellow }
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
Write-Log "Compare-NSX-Migration.ps1 v$ScriptVersion" INFO
Write-Log "Enter credentials for DESTINATION NSX Manager: $DestNSX" INFO
$DstCred    = Get-Credential -Message "DESTINATION NSX ($DestNSX) credentials"
$DstPair    = "$($DstCred.UserName):$($DstCred.GetNetworkCredential().Password)"
$DstBytes   = [System.Text.Encoding]::ASCII.GetBytes($DstPair)
$DstHeaders = @{
    Authorization  = "Basic $([Convert]::ToBase64String($DstBytes))"
    'Content-Type' = 'application/json'
}

# ─────────────────────────────────────────────────────────────
# REST HELPERS  (destination only)
# ─────────────────────────────────────────────────────────────
function Invoke-DstGet {
    param([string]$Path)
    $uri = "https://$DestNSX$Path"
    try {
        return Invoke-RestMethod -Uri $uri -Method GET -Headers $DstHeaders
    } catch {
        # 404 is expected for MISSING_DST — return $null silently
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) {
            return $null
        }
        Write-Log "GET $uri failed: $_" WARN
        return $null
    }
}

function Get-AllDstPages {
    param([string]$Path)
    $all    = @()
    $cursor = $null
    do {
        $url  = if ($cursor) { "${Path}?cursor=$cursor" } else { $Path }
        $resp = Invoke-DstGet -Path $url
        if ($null -eq $resp) { break }
        if ($resp.PSObject.Properties['results'] -and $resp.results) { $all += $resp.results }
        $cursor = if ($resp.PSObject.Properties['cursor']) { $resp.cursor } else { $null }
    } while ($cursor)
    return $all
}

function Test-DstConnectivity {
    Write-Log "Checking connectivity to destination NSX Manager: $DestNSX" INFO
    $info = Invoke-DstGet -Path '/api/v1/node'
    if ($info) {
        Write-Log "  Connected: NSX $($info.product_version)" SUCCESS
        return $true
    }
    Write-Log "  Cannot connect to destination NSX Manager." ERROR
    return $false
}

# ─────────────────────────────────────────────────────────────
# CSV FILE PICKER
# ─────────────────────────────────────────────────────────────
function Resolve-CsvFile {
    param([string]$Label, [string]$InitialDir = (Get-Location).Path)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    } catch {
        throw "System.Windows.Forms unavailable — cannot open file picker for '$Label'."
    }
    $dialog                  = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title            = "[$Label] Select the source CSV file"
    $dialog.InitialDirectory = $InitialDir
    $dialog.Filter           = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dialog.FilterIndex      = 1
    $dialog.Multiselect      = $false
    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "File picker cancelled for '$Label'. Aborting."
    }
    Write-Log "  [$Label] Selected: $(Split-Path $dialog.FileName -Leaf)" SUCCESS
    return $dialog.FileName
}

# ─────────────────────────────────────────────────────────────
# ID MAPPING TABLES
# ─────────────────────────────────────────────────────────────
$GroupIdMap   = @{}   # oldId -> newId for security groups
$ServiceIdMap = @{}   # oldId -> newId for services and service groups

function Load-MappingFile {
    param([string]$FilePath, [string]$Label)
    $map = @{}
    if (-not $FilePath) { return $map }
    if (-not (Test-Path $FilePath)) {
        Write-Log "[$Label] Mapping file not found: $FilePath — ID translation disabled." WARN
        return $map
    }
    $rows = Import-Csv -Path $FilePath -Encoding UTF8
    foreach ($row in $rows) {
        if ($row.PSObject.Properties['OldId'] -and $row.PSObject.Properties['NewId'] `
            -and $row.OldId -and $row.NewId) {
            $map[$row.OldId] = $row.NewId
        }
    }
    Write-Log "  [$Label] Loaded $($map.Count) ID mapping(s) from $(Split-Path $FilePath -Leaf)" INFO
    return $map
}

if ($GroupMappingFile)   { $GroupIdMap   = Load-MappingFile -FilePath $GroupMappingFile   -Label 'Groups'   }
if ($ServiceMappingFile) { $ServiceIdMap = Load-MappingFile -FilePath $ServiceMappingFile -Label 'Services' }

# ─────────────────────────────────────────────────────────────
# PATH REWRITING  (mirrors Sanitize-NSXFirewallRules.ps1 logic)
# ─────────────────────────────────────────────────────────────

# Rewrite /groups/<oldId> segments in any string using the group ID map.
function Update-GroupPaths {
    param([string]$text)
    if ($GroupIdMap.Count -eq 0) { return $text }
    $sortedKeys = $GroupIdMap.Keys | Sort-Object { $_.Length } -Descending
    foreach ($oldId in $sortedKeys) {
        $escaped = [regex]::Escape($oldId)
        $text = [regex]::Replace($text, "(?<=/groups/)$escaped(?=/|`"|$)", $GroupIdMap[$oldId])
    }
    return $text
}

# Rewrite /services/<oldId> segments in any string using the service ID map.
function Update-ServicePaths {
    param([string]$text)
    if ($ServiceIdMap.Count -eq 0) { return $text }
    $sortedKeys = $ServiceIdMap.Keys | Sort-Object { $_.Length } -Descending
    foreach ($oldId in $sortedKeys) {
        $escaped = [regex]::Escape($oldId)
        $text = [regex]::Replace($text, "(?<=/services/)$escaped(?=/|`"|$)", $ServiceIdMap[$oldId])
    }
    return $text
}

# Rewrite /context-profiles/<oldId> segments (profiles use display_name as ID,
# so typically no mapping needed, but kept for completeness).
function Update-ProfilePaths {
    param([string]$text)
    # Context profiles are not renamed by the sanitize pipeline, so no rewriting needed.
    return $text
}

# Translate a source object ID to its mapped destination ID.
function Resolve-Id {
    param([string]$Id, [hashtable]$IdMap)
    if ($IdMap.ContainsKey($Id)) { return $IdMap[$Id] }
    return $Id
}

# ─────────────────────────────────────────────────────────────
# JSON NORMALIZATION
#
# To make two JSON strings comparable regardless of key ordering or
# whitespace differences, we parse both into PSObjects and re-serialize
# them with sorted keys.
# ─────────────────────────────────────────────────────────────

# Read-only fields that NSX adds on every GET response.
# These are stripped from destination payloads before comparison.
$ReadOnlyFields = @(
    '_create_time', '_last_modified_time', '_system_owned', '_revision',
    '_create_user', '_last_modified_user', '_protection',
    'path', 'parent_path', 'relative_path', 'unique_id', 'marked_for_delete',
    'overridden', 'owner_id', 'sequence_number'   # sequence_number is managed by NSX internally
)

# Strip read-only fields from a deserialized PSObject (recursive).
function Remove-ReadOnlyFields {
    param([object]$Obj)
    if ($null -eq $Obj) { return $Obj }

    # Handle arrays
    if ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string]) {
        return @($Obj | ForEach-Object { Remove-ReadOnlyFields $_ })
    }

    # Handle PSCustomObject
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $clone = [ordered]@{}
        foreach ($prop in ($Obj.PSObject.Properties | Sort-Object Name)) {
            if ($prop.Name -notin $ReadOnlyFields) {
                $clone[$prop.Name] = Remove-ReadOnlyFields $prop.Value
            }
        }
        return [PSCustomObject]$clone
    }

    # Scalar — return as-is
    return $Obj
}

# Normalize a JSON string: parse → strip read-only fields → re-serialize with sorted keys.
function Normalize-Json {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return '' }
    try {
        $obj     = $Json | ConvertFrom-Json
        $cleaned = Remove-ReadOnlyFields $obj
        return ($cleaned | ConvertTo-Json -Depth 20 -Compress)
    } catch {
        Write-Log "    JSON normalization failed: $_" WARN
        return $Json
    }
}

# ─────────────────────────────────────────────────────────────
# STATISTICS & FINDINGS
# ─────────────────────────────────────────────────────────────
$Stats = [ordered]@{
    Services_Match      = 0; Services_Mismatch    = 0; Services_MissingDst   = 0; Services_ExtraDst   = 0
    Groups_Match        = 0; Groups_Mismatch      = 0; Groups_MissingDst     = 0; Groups_ExtraDst     = 0
    Profiles_Match      = 0; Profiles_Mismatch    = 0; Profiles_MissingDst   = 0; Profiles_ExtraDst   = 0
    Policies_Match      = 0; Policies_Mismatch    = 0; Policies_MissingDst   = 0; Policies_ExtraDst   = 0
    Rules_Match         = 0; Rules_Mismatch       = 0; Rules_MissingDst      = 0; Rules_ExtraDst      = 0
    Errors              = 0
}

$Findings = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Finding {
    param(
        [string]$ObjectType,
        [string]$ObjectId,
        [string]$DisplayName,
        [ValidateSet('MATCH','MISMATCH','MISSING_DST','EXTRA_DST')][string]$Result,
        [string]$Detail = ''
    )
    $Findings.Add([PSCustomObject]@{
        ObjectType  = $ObjectType
        ObjectId    = $ObjectId
        DisplayName = $DisplayName
        Result      = $Result
        Detail      = $Detail
    })
}

# ─────────────────────────────────────────────────────────────
# UPFRONT CSV FILE SELECTION
# ─────────────────────────────────────────────────────────────
Write-Log "════════════════════════════════════════════════════════════════════" INFO
Write-Log " FILE SELECTION — select source CSV files" INFO
Write-Log "════════════════════════════════════════════════════════════════════" INFO

$Script:CsvPath_Services = $null
$Script:CsvPath_Groups   = $null
$Script:CsvPath_Profiles      = $null
$Script:CsvPath_Policies      = $null
$Script:CsvPath_Rules         = $null

$InitialDir = (Get-Location).Path

if ($CompareServices) {
    $Script:CsvPath_Services = Resolve-CsvFile -Label 'Services' -InitialDir $InitialDir
}
if ($CompareGroups)   { $Script:CsvPath_Groups   = Resolve-CsvFile -Label 'Security Groups'  -InitialDir $InitialDir }
if ($CompareProfiles) { $Script:CsvPath_Profiles = Resolve-CsvFile -Label 'Context Profiles' -InitialDir $InitialDir }
if ($ComparePolicies) {
    $Script:CsvPath_Policies = Resolve-CsvFile -Label 'DFW Policies' -InitialDir $InitialDir
    $Script:CsvPath_Rules    = Resolve-CsvFile -Label 'DFW Rules'    -InitialDir $InitialDir
}

Write-Log " All CSV files selected." SUCCESS

# ─────────────────────────────────────────────────────────────
# CORE COMPARE FUNCTION
#
# Given a list of source rows (with Id + RawJson already rewritten),
# a map of destination objects (id -> normalized JSON), and an object
# type label, this function records MATCH / MISMATCH / MISSING_DST
# findings and returns the count of each.
# EXTRA_DST objects (on dst but not in source CSV) are detected separately
# per object type after the per-row loop.
# ─────────────────────────────────────────────────────────────
function Compare-Objects {
    param(
        [string]$TypeLabel,
        [object[]]$SourceRows,          # CSV rows with Id and RawJson (already remapped)
        [hashtable]$DstMap,             # id (string) -> normalized JSON (string) from destination
        [string]$StatPrefix             # e.g. 'Services' to update $Stats.Services_Match etc.
    )

    $matched    = 0
    $mismatched = 0
    $missingDst = 0

    $seenIds = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($row in $SourceRows) {
        $id          = $row.Id
        $displayName = if ($row.PSObject.Properties['DisplayName']) { $row.DisplayName } else { $id }

        [void]$seenIds.Add($id)

        # Normalize the source expected JSON
        $expectedJson = Normalize-Json -Json $row.RawJson

        if (-not $DstMap.ContainsKey($id)) {
            Write-Log "    ✗ MISSING_DST : [$TypeLabel] $id ($displayName)" WARN
            Add-Finding -ObjectType $TypeLabel -ObjectId $id -DisplayName $displayName `
                        -Result 'MISSING_DST'
            $missingDst++
            continue
        }

        $actualJson = $DstMap[$id]

        if ($expectedJson -eq $actualJson) {
            Write-Log "    ✔ MATCH       : [$TypeLabel] $id ($displayName)" SUCCESS
            Add-Finding -ObjectType $TypeLabel -ObjectId $id -DisplayName $displayName -Result 'MATCH'
            $matched++
        } else {
            # Produce a brief diff hint by finding the first differing key
            $detail = Get-JsonDiffHint -Expected $expectedJson -Actual $actualJson
            Write-Log "    ⚠ MISMATCH    : [$TypeLabel] $id ($displayName) — $detail" WARN
            Add-Finding -ObjectType $TypeLabel -ObjectId $id -DisplayName $displayName `
                        -Result 'MISMATCH' -Detail $detail
            $mismatched++
        }
    }

    # Detect EXTRA_DST objects
    $extraDst = 0
    foreach ($dstId in $DstMap.Keys) {
        if (-not $seenIds.Contains($dstId)) {
            Write-Log "    ⚠ EXTRA_DST   : [$TypeLabel] $dstId (not in source CSV)" WARN
            Add-Finding -ObjectType $TypeLabel -ObjectId $dstId -DisplayName '' -Result 'EXTRA_DST' `
                        -Detail 'Object exists on destination but was not present in source CSV'
            $extraDst++
        }
    }

    $Stats["${StatPrefix}_Match"]      += $matched
    $Stats["${StatPrefix}_Mismatch"]   += $mismatched
    $Stats["${StatPrefix}_MissingDst"] += $missingDst
    $Stats["${StatPrefix}_ExtraDst"]   += $extraDst

    Write-Log ("  Result: {0} match | {1} mismatch | {2} missing on dst | {3} extra on dst" `
        -f $matched, $mismatched, $missingDst, $extraDst) INFO
}

# Produce a short hint string showing the first key that differs between two JSON strings.
function Get-JsonDiffHint {
    param([string]$Expected, [string]$Actual)
    try {
        $exp = $Expected | ConvertFrom-Json
        $act = $Actual   | ConvertFrom-Json
        foreach ($prop in $exp.PSObject.Properties) {
            $expVal = ($prop.Value | ConvertTo-Json -Depth 5 -Compress)
            $actProp = $act.PSObject.Properties[$prop.Name]
            if (-not $actProp) { return "missing field '$($prop.Name)' on destination" }
            $actVal = ($actProp.Value | ConvertTo-Json -Depth 5 -Compress)
            if ($expVal -ne $actVal) {
                $truncExp = if ($expVal.Length -gt 60) { $expVal.Substring(0,60) + '…' } else { $expVal }
                $truncAct = if ($actVal.Length -gt 60) { $actVal.Substring(0,60) + '…' } else { $actVal }
                return "'$($prop.Name)': expected=$truncExp actual=$truncAct"
            }
        }
        # Check for extra fields on destination
        foreach ($prop in $act.PSObject.Properties) {
            if (-not $exp.PSObject.Properties[$prop.Name]) {
                return "extra field '$($prop.Name)' on destination"
            }
        }
        return 'no diff detected after re-parse (possible whitespace/ordering difference)'
    } catch {
        return 'could not parse JSON for diff hint'
    }
}

# ─────────────────────────────────────────────────────────────
# COMPARE SERVICES & SERVICE GROUPS
# ─────────────────────────────────────────────────────────────
function Compare-Services {
    Write-Log "" INFO
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" INFO
    Write-Log "  COMPARING SERVICES & SERVICE GROUPS" INFO
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" INFO

    # Load source rows from Services CSV only
    $svcRows = @()
    if ($Script:CsvPath_Services -and (Test-Path $Script:CsvPath_Services)) {
        $svcRows = @(Import-Csv -Path $Script:CsvPath_Services -Encoding UTF8)
        Write-Log "  Loaded $($svcRows.Count) Service row(s) from CSV." INFO
    }

    $allSrcRows = $svcRows
    if ($allSrcRows.Count -eq 0) { Write-Log "  No source rows to compare." WARN; return }

    # Apply service ID mapping and rewrite paths in RawJson
    $remappedRows = foreach ($row in $allSrcRows) {
        $newId      = Resolve-Id -Id $row.Id -IdMap $ServiceIdMap
        $oldDisplay = if ($row.PSObject.Properties['DisplayName']) { $row.DisplayName } else { $row.Id }
        $newRawJson = Update-ServicePaths -text $row.RawJson
        # Rewrite "id", "relative_path", and "display_name" inside the JSON —
        # mirrors what Sanitize-NSXServices.ps1 does when Id != DisplayName
        if ($row.Id -ne $newId) {
            $escOldId      = [regex]::Escape($row.Id)
            $escOldDisplay = [regex]::Escape($oldDisplay)
            $newRawJson = [regex]::Replace($newRawJson, '"id"\s*:\s*"' + $escOldId + '"',                  '"id":"'           + $newId + '"')
            $newRawJson = [regex]::Replace($newRawJson, '"relative_path"\s*:\s*"' + $escOldId + '"',       '"relative_path":"' + $newId + '"')
            $newRawJson = [regex]::Replace($newRawJson, '"display_name"\s*:\s*"' + $escOldDisplay + '"',   '"display_name":"'  + $newId + '"')
        }
        [PSCustomObject]@{
            Id          = $newId
            DisplayName = $oldDisplay
            RawJson     = $newRawJson
        }
    }

    # Fetch all services from destination into a hashtable id -> normalizedJson
    Write-Log "  Fetching all Services from destination ($DestNSX)..." INFO
    $dstAll  = Get-AllDstPages -Path '/policy/api/v1/infra/services'
    $dstMap  = @{}
    foreach ($obj in $dstAll) {
        if ((Get-SafeProp $obj '_system_owned') -eq $true) { continue }
        $dstMap[$obj.id] = Normalize-Json -Json ($obj | ConvertTo-Json -Depth 20 -Compress)
    }
    Write-Log "  Destination has $($dstMap.Count) custom Service/ServiceGroup object(s)." INFO

    Compare-Objects -TypeLabel 'Service' -SourceRows $remappedRows -DstMap $dstMap -StatPrefix 'Services'
}

# ─────────────────────────────────────────────────────────────
# COMPARE SECURITY GROUPS
# ─────────────────────────────────────────────────────────────
function Compare-Groups {
    Write-Log "" INFO
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" INFO
    Write-Log "  COMPARING SECURITY GROUPS" INFO
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" INFO

    $srcRows = @()
    if ($Script:CsvPath_Groups -and (Test-Path $Script:CsvPath_Groups)) {
        $srcRows = @(Import-Csv -Path $Script:CsvPath_Groups -Encoding UTF8)
        Write-Log "  Loaded $($srcRows.Count) Group row(s) from CSV." INFO
    }
    if ($srcRows.Count -eq 0) { Write-Log "  No source rows to compare." WARN; return }

    # Apply group ID mapping and rewrite path references in RawJson
    $remappedRows = foreach ($row in $srcRows) {
        $newId      = Resolve-Id -Id $row.Id -IdMap $GroupIdMap
        $oldDisplay = if ($row.PSObject.Properties['DisplayName']) { $row.DisplayName } else { $row.Id }
        $newRawJson = Update-GroupPaths   -text $row.RawJson
        $newRawJson = Update-ServicePaths -text $newRawJson
        # Rewrite "id", "relative_path", and "display_name" inside the JSON —
        # mirrors what Sanitize-NSXGroups.ps1 does when Id != DisplayName
        if ($row.Id -ne $newId) {
            $escOldId      = [regex]::Escape($row.Id)
            $escOldDisplay = [regex]::Escape($oldDisplay)
            $newRawJson = [regex]::Replace($newRawJson, '"id"\s*:\s*"' + $escOldId + '"',                 '"id":"'           + $newId + '"')
            $newRawJson = [regex]::Replace($newRawJson, '"relative_path"\s*:\s*"' + $escOldId + '"',      '"relative_path":"' + $newId + '"')
            $newRawJson = [regex]::Replace($newRawJson, '"display_name"\s*:\s*"' + $escOldDisplay + '"',  '"display_name":"'  + $newId + '"')
        }
        [PSCustomObject]@{
            Id          = $newId
            DisplayName = $oldDisplay
            RawJson     = $newRawJson
        }
    }

    # Fetch all groups from destination
    Write-Log "  Fetching all Security Groups from destination ($DestNSX)..." INFO
    $dstAll = Get-AllDstPages -Path "/policy/api/v1/infra/domains/$DomainId/groups"
    $dstMap = @{}
    foreach ($obj in $dstAll) {
        if ((Get-SafeProp $obj '_system_owned') -eq $true) { continue }
        if ((Get-SafeProp $obj '_create_user')  -eq 'system') { continue }
        $dstMap[$obj.id] = Normalize-Json -Json ($obj | ConvertTo-Json -Depth 20 -Compress)
    }
    Write-Log "  Destination has $($dstMap.Count) custom Security Group(s)." INFO

    Compare-Objects -TypeLabel 'Group' -SourceRows $remappedRows -DstMap $dstMap -StatPrefix 'Groups'
}

# ─────────────────────────────────────────────────────────────
# COMPARE CONTEXT PROFILES
# ─────────────────────────────────────────────────────────────
function Compare-Profiles {
    Write-Log "" INFO
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" INFO
    Write-Log "  COMPARING CONTEXT PROFILES" INFO
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" INFO

    $srcRows = @()
    if ($Script:CsvPath_Profiles -and (Test-Path $Script:CsvPath_Profiles)) {
        $srcRows = @(Import-Csv -Path $Script:CsvPath_Profiles -Encoding UTF8)
        Write-Log "  Loaded $($srcRows.Count) Context Profile row(s) from CSV." INFO
    }
    if ($srcRows.Count -eq 0) { Write-Log "  No source rows to compare." WARN; return }

    # Context profiles are not renamed by the sanitize pipeline — IDs stay as-is
    $remappedRows = foreach ($row in $srcRows) {
        [PSCustomObject]@{
            Id          = $row.Id
            DisplayName = if ($row.PSObject.Properties['DisplayName']) { $row.DisplayName } else { $row.Id }
            RawJson     = $row.RawJson
        }
    }

    # Fetch all context profiles from destination
    Write-Log "  Fetching all Context Profiles from destination ($DestNSX)..." INFO
    $dstAll = Get-AllDstPages -Path '/policy/api/v1/infra/context-profiles'
    $dstMap = @{}
    foreach ($obj in $dstAll) {
        if ((Get-SafeProp $obj '_system_owned') -eq $true) { continue }
        $dstMap[$obj.id] = Normalize-Json -Json ($obj | ConvertTo-Json -Depth 20 -Compress)
    }
    Write-Log "  Destination has $($dstMap.Count) custom Context Profile(s)." INFO

    Compare-Objects -TypeLabel 'ContextProfile' -SourceRows $remappedRows -DstMap $dstMap -StatPrefix 'Profiles'
}

# ─────────────────────────────────────────────────────────────
# COMPARE DFW POLICIES & RULES
# ─────────────────────────────────────────────────────────────
function Compare-Policies {
    Write-Log "" INFO
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" INFO
    Write-Log "  COMPARING DFW POLICIES" INFO
    Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" INFO

    $polRows  = @()
    $ruleRows = @()
    if ($Script:CsvPath_Policies -and (Test-Path $Script:CsvPath_Policies)) {
        $polRows = @(Import-Csv -Path $Script:CsvPath_Policies -Encoding UTF8)
        Write-Log "  Loaded $($polRows.Count) Policy row(s) from CSV." INFO
    }
    if ($Script:CsvPath_Rules -and (Test-Path $Script:CsvPath_Rules)) {
        $ruleRows = @(Import-Csv -Path $Script:CsvPath_Rules -Encoding UTF8)
        Write-Log "  Loaded $($ruleRows.Count) Rule row(s) from CSV." INFO
    }

    # ── Policies ─────────────────────────────────────────────
    if ($polRows.Count -gt 0) {
        Write-Log "  Fetching all DFW Policies from destination ($DestNSX)..." INFO
        $dstPolAll = Get-AllDstPages -Path "/policy/api/v1/infra/domains/$DomainId/security-policies"
        $dstPolMap = @{}
        foreach ($obj in $dstPolAll) {
            if ((Get-SafeProp $obj '_system_owned') -eq $true) { continue }
            $dstPolMap[$obj.id] = Normalize-Json -Json ($obj | ConvertTo-Json -Depth 20 -Compress)
        }
        Write-Log "  Destination has $($dstPolMap.Count) custom DFW Policy/Policies." INFO

        $remappedPols = foreach ($row in $polRows) {
            $newRawJson = Update-GroupPaths -text $row.RawJson
            [PSCustomObject]@{
                Id          = $row.Id
                DisplayName = if ($row.PSObject.Properties['DisplayName']) { $row.DisplayName } else { $row.Id }
                RawJson     = $newRawJson
            }
        }

        Write-Log "  --- Policies ---" INFO
        Compare-Objects -TypeLabel 'Policy' -SourceRows $remappedPols -DstMap $dstPolMap -StatPrefix 'Policies'
    }

    # ── Rules ────────────────────────────────────────────────
    if ($ruleRows.Count -gt 0) {
        Write-Log "" INFO
        Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" INFO
        Write-Log "  COMPARING DFW RULES" INFO
        Write-Log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" INFO

        # Group rule rows by PolicyId so we can fetch per-policy rules from the dst
        # The Rules CSV must have a PolicyId column (produced by Export-NSX-DFW.ps1)
        $rulesByPolicy = @{}
        foreach ($row in $ruleRows) {
            $policyId = if ($row.PSObject.Properties['PolicyId']) { $row.PolicyId } else { '' }
            if (-not $rulesByPolicy.ContainsKey($policyId)) { $rulesByPolicy[$policyId] = @() }
            $rulesByPolicy[$policyId] += $row
        }

        foreach ($policyId in ($rulesByPolicy.Keys | Sort-Object)) {
            Write-Log "  Fetching rules for Policy '$policyId' from destination..." INFO
            $dstRulesAll = Get-AllDstPages -Path "/policy/api/v1/infra/domains/$DomainId/security-policies/$policyId/rules"
            $dstRuleMap  = @{}
            foreach ($obj in $dstRulesAll) {
                $dstRuleMap[$obj.id] = Normalize-Json -Json ($obj | ConvertTo-Json -Depth 20 -Compress)
            }
            Write-Log "    Destination has $($dstRuleMap.Count) rule(s) in policy '$policyId'." INFO

            $remappedRules = foreach ($row in $rulesByPolicy[$policyId]) {
                $newRawJson = Update-GroupPaths   -text $row.RawJson
                $newRawJson = Update-ServicePaths -text $newRawJson
                [PSCustomObject]@{
                    Id          = $row.Id
                    DisplayName = if ($row.PSObject.Properties['DisplayName']) { $row.DisplayName } else { $row.Id }
                    RawJson     = $newRawJson
                }
            }

            Compare-Objects -TypeLabel "Rule[$policyId]" -SourceRows $remappedRules -DstMap $dstRuleMap -StatPrefix 'Rules'
        }
    }
}

# ─────────────────────────────────────────────────────────────
# SAFE PROPERTY HELPER
# ─────────────────────────────────────────────────────────────
function Get-SafeProp {
    param([object]$Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    return $null
}

# ─────────────────────────────────────────────────────────────
# REPORT EXPORT
# ─────────────────────────────────────────────────────────────
function Export-CsvReport {
    $csvPath = Join-Path $OutputFolder "NSX_Validation_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $Findings | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Log "  CSV report written: $csvPath" SUCCESS
    return $csvPath
}

function Export-HtmlReport {
    param([string]$CsvPath)
    $htmlPath = $CsvPath -replace '\.csv$', '.html'
    $ts       = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $totalMatch      = ($Stats.Services_Match      + $Stats.Groups_Match      + $Stats.Profiles_Match      + $Stats.Policies_Match      + $Stats.Rules_Match)
    $totalMismatch   = ($Stats.Services_Mismatch   + $Stats.Groups_Mismatch   + $Stats.Profiles_Mismatch   + $Stats.Policies_Mismatch   + $Stats.Rules_Mismatch)
    $totalMissingDst = ($Stats.Services_MissingDst + $Stats.Groups_MissingDst + $Stats.Profiles_MissingDst + $Stats.Policies_MissingDst + $Stats.Rules_MissingDst)
    $totalExtraDst   = ($Stats.Services_ExtraDst   + $Stats.Groups_ExtraDst   + $Stats.Profiles_ExtraDst   + $Stats.Policies_ExtraDst   + $Stats.Rules_ExtraDst)
    $overallStatus   = if ($totalMismatch -eq 0 -and $totalMissingDst -eq 0) { 'PASSED ✔' } else { 'ISSUES FOUND ⚠' }
    $statusColor     = if ($overallStatus -like '*PASSED*') { '#27ae60' } else { '#e67e22' }

    $rowsHtml = foreach ($f in $Findings) {
        $color = switch ($f.Result) {
            'MATCH'       { '#27ae60' }
            'MISMATCH'    { '#e67e22' }
            'MISSING_DST' { '#e74c3c' }
            'EXTRA_DST'   { '#8e44ad' }
            default       { '#333'    }
        }
        $icon = switch ($f.Result) {
            'MATCH'       { '✔' }
            'MISMATCH'    { '⚠' }
            'MISSING_DST' { '✗' }
            'EXTRA_DST'   { '⚠' }
            default       { '?' }
        }
        $detailHtml = [System.Web.HttpUtility]::HtmlEncode($f.Detail)
        "<tr>
            <td>$([System.Web.HttpUtility]::HtmlEncode($f.ObjectType))</td>
            <td>$([System.Web.HttpUtility]::HtmlEncode($f.ObjectId))</td>
            <td>$([System.Web.HttpUtility]::HtmlEncode($f.DisplayName))</td>
            <td style='color:$color;font-weight:bold'>$icon $($f.Result)</td>
            <td style='font-size:0.85em;color:#555'>$detailHtml</td>
        </tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>NSX Migration Validation Report</title>
<style>
  body { font-family: Segoe UI, Arial, sans-serif; margin: 40px; color: #222; background: #f5f6fa; }
  h1   { color: #2c3e50; }
  .summary-box { background: #fff; border-radius: 8px; padding: 24px 32px; margin-bottom: 32px;
                 box-shadow: 0 2px 8px rgba(0,0,0,0.08); display: inline-block; min-width: 600px; }
  .status { font-size: 1.4em; font-weight: bold; color: $statusColor; margin-bottom: 12px; }
  table  { border-collapse: collapse; width: 100%; background: #fff; border-radius: 8px;
           box-shadow: 0 2px 8px rgba(0,0,0,0.08); overflow: hidden; }
  th     { background: #2c3e50; color: #fff; padding: 10px 14px; text-align: left; }
  td     { padding: 8px 14px; border-bottom: 1px solid #eee; vertical-align: top; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #f0f4f8; }
  .stat  { display: inline-block; margin: 4px 12px 4px 0; }
  .stat span { font-weight: bold; font-size: 1.1em; }
  small  { color: #888; }
</style>
</head>
<body>
<h1>NSX DFW Migration Validation Report</h1>
<div class="summary-box">
  <div class="status">Overall: $overallStatus</div>
  <div><small>Generated: $ts &nbsp;|&nbsp; Destination: $DestNSX</small></div>
  <br>
  <div class="stat">✔ Match: <span style="color:#27ae60">$totalMatch</span></div>
  <div class="stat">⚠ Mismatch: <span style="color:#e67e22">$totalMismatch</span></div>
  <div class="stat">✗ Missing on Dst: <span style="color:#e74c3c">$totalMissingDst</span></div>
  <div class="stat">⚠ Extra on Dst: <span style="color:#8e44ad">$totalExtraDst</span></div>
  <br><br>
  <table style="box-shadow:none;width:auto">
    <tr><th>Object Type</th><th>Match</th><th>Mismatch</th><th>Missing Dst</th><th>Extra Dst</th></tr>
    <tr><td>Services</td><td>$($Stats.Services_Match)</td><td>$($Stats.Services_Mismatch)</td><td>$($Stats.Services_MissingDst)</td><td>$($Stats.Services_ExtraDst)</td></tr>
    <tr><td>Groups</td><td>$($Stats.Groups_Match)</td><td>$($Stats.Groups_Mismatch)</td><td>$($Stats.Groups_MissingDst)</td><td>$($Stats.Groups_ExtraDst)</td></tr>
    <tr><td>Context Profiles</td><td>$($Stats.Profiles_Match)</td><td>$($Stats.Profiles_Mismatch)</td><td>$($Stats.Profiles_MissingDst)</td><td>$($Stats.Profiles_ExtraDst)</td></tr>
    <tr><td>Policies</td><td>$($Stats.Policies_Match)</td><td>$($Stats.Policies_Mismatch)</td><td>$($Stats.Policies_MissingDst)</td><td>$($Stats.Policies_ExtraDst)</td></tr>
    <tr><td>Rules</td><td>$($Stats.Rules_Match)</td><td>$($Stats.Rules_Mismatch)</td><td>$($Stats.Rules_MissingDst)</td><td>$($Stats.Rules_ExtraDst)</td></tr>
  </table>
</div>

<h2>Detailed Findings</h2>
<table>
  <tr>
    <th>Object Type</th>
    <th>Object ID</th>
    <th>Display Name</th>
    <th>Result</th>
    <th>Detail</th>
  </tr>
  $($rowsHtml -join "`n  ")
</table>
</body>
</html>
"@

    # HttpUtility may not be available without loading the assembly
    try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}

    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Log "  HTML report written: $htmlPath" SUCCESS
    return $htmlPath
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────
Write-Log "════════════════════════════════════════════════════════════════════" INFO
Write-Log " NSX DFW MIGRATION VALIDATION  v$ScriptVersion" INFO
Write-Log " Destination : $DestNSX" INFO
Write-Log " Domain      : $DomainId" INFO
Write-Log " Output      : $OutputFolder" INFO
Write-Log "════════════════════════════════════════════════════════════════════" INFO

try {
    if (-not (Test-DstConnectivity)) {
        Write-Log "Destination connectivity check failed. Aborting." ERROR
        exit 1
    }

    if ($CompareServices) { Compare-Services }
    if ($CompareGroups)   { Compare-Groups   }
    if ($CompareProfiles) { Compare-Profiles }
    if ($ComparePolicies) { Compare-Policies }

    Write-Log "" INFO
    Write-Log "════════════════════════════════════════════════════════════════════" INFO
    Write-Log " GENERATING REPORTS" INFO
    Write-Log "════════════════════════════════════════════════════════════════════" INFO

    $csvPath  = Export-CsvReport
    $htmlPath = Export-HtmlReport -CsvPath $csvPath

} catch {
    Write-Log "FATAL ERROR: $_" ERROR
    $Stats.Errors++
    exit 1
} finally {
    $totalMatch      = ($Stats.Services_Match      + $Stats.Groups_Match      + $Stats.Profiles_Match      + $Stats.Policies_Match      + $Stats.Rules_Match)
    $totalMismatch   = ($Stats.Services_Mismatch   + $Stats.Groups_Mismatch   + $Stats.Profiles_Mismatch   + $Stats.Policies_Mismatch   + $Stats.Rules_Mismatch)
    $totalMissingDst = ($Stats.Services_MissingDst + $Stats.Groups_MissingDst + $Stats.Profiles_MissingDst + $Stats.Policies_MissingDst + $Stats.Rules_MissingDst)
    $totalExtraDst   = ($Stats.Services_ExtraDst   + $Stats.Groups_ExtraDst   + $Stats.Profiles_ExtraDst   + $Stats.Policies_ExtraDst   + $Stats.Rules_ExtraDst)
    $overallStatus   = if ($totalMismatch -eq 0 -and $totalMissingDst -eq 0) { 'PASSED ✔' } else { 'ISSUES FOUND ⚠' }

    Write-Log "" INFO
    Write-Log "════════════════════════════════════════════════════════════════════" INFO
    Write-Log " VALIDATION SUMMARY" INFO
    Write-Log "────────────────────────────────────────────────────────────────────" INFO
    Write-Log ("  {0,-20} {1,8} {2,10} {3,12} {4,10}" -f 'Object Type','Match','Mismatch','Missing Dst','Extra Dst') INFO
    Write-Log "  ─────────────────────────────────────────────────────────────────" INFO
    Write-Log ("  {0,-20} {1,8} {2,10} {3,12} {4,10}" -f 'Services'       ,$Stats.Services_Match ,$Stats.Services_Mismatch ,$Stats.Services_MissingDst ,$Stats.Services_ExtraDst) INFO
    Write-Log ("  {0,-20} {1,8} {2,10} {3,12} {4,10}" -f 'Groups'         ,$Stats.Groups_Match   ,$Stats.Groups_Mismatch   ,$Stats.Groups_MissingDst   ,$Stats.Groups_ExtraDst)   INFO
    Write-Log ("  {0,-20} {1,8} {2,10} {3,12} {4,10}" -f 'Context Profiles',$Stats.Profiles_Match,$Stats.Profiles_Mismatch ,$Stats.Profiles_MissingDst ,$Stats.Profiles_ExtraDst) INFO
    Write-Log ("  {0,-20} {1,8} {2,10} {3,12} {4,10}" -f 'Policies'       ,$Stats.Policies_Match ,$Stats.Policies_Mismatch ,$Stats.Policies_MissingDst ,$Stats.Policies_ExtraDst) INFO
    Write-Log ("  {0,-20} {1,8} {2,10} {3,12} {4,10}" -f 'Rules'          ,$Stats.Rules_Match    ,$Stats.Rules_Mismatch    ,$Stats.Rules_MissingDst    ,$Stats.Rules_ExtraDst)    INFO
    Write-Log "  ─────────────────────────────────────────────────────────────────" INFO
    Write-Log ("  {0,-20} {1,8} {2,10} {3,12} {4,10}" -f 'TOTAL',$totalMatch,$totalMismatch,$totalMissingDst,$totalExtraDst) INFO
    Write-Log "" INFO
    Write-Log "  Overall status : $overallStatus" INFO
    if ($Stats.Errors -gt 0) {
        Write-Log "  Errors         : $($Stats.Errors)" ERROR
    }
    Write-Log "════════════════════════════════════════════════════════════════════" INFO
}
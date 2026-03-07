# =============================================================================
# Get-NSXTagsInUse.ps1  —  Shared helper / dot-source module
# Version 1.0.0
#
# PURPOSE
# -------
# Discovers which tag scope:value pairs are actively referenced inside security
# group membership expressions, so the sanitization scripts can preserve those
# tags rather than blindly removing them as migration artefacts.
#
# A tag is considered "in use" when any security group contains a Condition
# expression with key = "Tag". This covers ALL member_type values:
#
#   member_type: VirtualMachine  — group includes VMs carrying the tag
#   member_type: Group           — group includes OTHER GROUPS carrying the tag
#   member_type: VIF             — group includes virtual interfaces by tag
#   member_type: Segment         — group includes segments by tag
#   member_type: SegmentPort     — group includes segment ports by tag
#
# The Group member_type case is the critical one for sanitization: if group A
# has tags:[{scope:"tier", tag:"web"}] on itself, and group B has a Condition
# with member_type=Group, key=Tag, value="tier|web", then group A is a dynamic
# member of group B. Stripping group A's tag would silently remove it from
# group B's membership — breaking firewall coverage with no API error.
#
# TWO-PHASE APPROACH
# ------------------
# Phase 1 — CSV scan (always runs, no credentials needed):
#   Parses NSX_Groups.csv and extracts all Tag Conditions from the RawJson of
#   every exported group. This covers all user-created groups and is instant.
#
# Phase 2 — Live API scan of system-owned groups only (optional, recommended):
#   System-owned groups are never exported to CSV, but they CAN contain Tag
#   Conditions that reference tags on user-created groups. If -NSXManager is
#   provided, a targeted API call fetches ONLY system-owned groups and scans
#   them too. This closes the one blind spot that CSV-only cannot cover, while
#   avoiding a full re-fetch of all groups already scanned in Phase 1.
#
#   If -NSXManager is omitted, Phase 2 is skipped and a note is logged. This
#   is safe in environments where system-owned groups do not use Tag Conditions
#   with member_type=Group, which is the common case.
#
# RETURN VALUE
# ------------
# Returns a hashtable. Each key is a tag identifier in one of two formats:
#   "scope|value"  — when the Condition value contains a pipe separator
#   "value"        — when the Condition has no scope qualifier
#
# Each value is an array of strings in the form:
#   "GroupDisplayName [member_type=X] [source=csv|system]"
#
# The source annotation makes it clear whether the consuming group came from
# the CSV export or from a system-owned group found via the live API.
#
# EXPRESSION TYPES SCANNED
# ------------------------
#   Condition        — direct tag match (any member_type)
#   NestedExpression — Conditions nested inside a conjunction block
#
# HOW TO USE FROM A SANITIZATION SCRIPT
# --------------------------------------
#   . "$PSScriptRoot\Get-NSXTagsInUse.ps1"
#
#   # CSV-only (fully offline):
#   $inUseTags = Get-NSXTagsInUse -GroupsCsv ".\NSX_Groups.csv"
#
#   # CSV + system-owned groups from live API (recommended):
#   $inUseTags = Get-NSXTagsInUse -GroupsCsv   ".\NSX_Groups.csv"  `
#                                 -NSXManager  "nsx4.corp.local"    `
#                                 -Headers     $Headers             `
#                                 -DomainId    "default"
#
# KNOWN LIMITATIONS
# -----------------
#   - Tags referenced in Gateway Firewall policy conditions are not scanned.
#     DFW-only scope is assumed.
#   - If the Phase 2 API call fails, a warning is logged and the function
#     returns the CSV-only results rather than failing. The caller will see
#     a clear warning that system-owned groups were not checked.
# =============================================================================

function Get-NSXTagsInUse {
    <#
    .SYNOPSIS
        Returns a hashtable of tag identifiers in use across security group
        membership expressions, built from a CSV scan (Phase 1) optionally
        supplemented by a live API scan of system-owned groups (Phase 2).

    .PARAMETER GroupsCsv
        Path to NSX_Groups.csv produced by Export-NSX-DFW.ps1.
        Required — Phase 1 always runs against this file.

    .PARAMETER NSXManager
        FQDN or IP of the NSX Manager. Optional — enables Phase 2 (system-owned
        group scan via live API). If omitted, only the CSV is scanned.

    .PARAMETER Headers
        Hashtable of HTTP headers including Authorization. Required when
        -NSXManager is provided.

    .PARAMETER DomainId
        NSX Policy domain to scan in Phase 2. Default: "default"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GroupsCsv,
        [string]   $NSXManager = '',
        [hashtable]$Headers    = @{},
        [string]   $DomainId   = 'default'
    )

    $inUse = @{}   # tag key -> [string[]] "groupName [member_type=X] [source=Y]"

    # ─────────────────────────────────────────────────────────────────────────
    # Inner helper — scans a flat list of already-parsed group objects and
    # populates $inUse. Defined here rather than as a nested function because
    # PowerShell nested functions cannot write to a parent-scope variable via
    # the script: scope modifier when dot-sourced; using a script-level
    # hashtable and passing it by reference via the enclosing scope is simpler.
    #
    # $Source is 'csv' or 'system' — appended to each entry so the caller can
    # see which phase detected the consuming group.
    # Returns the count of NEW unique tag values added by this call.
    # ─────────────────────────────────────────────────────────────────────────
    function Invoke-GroupScan {
        param(
            [object[]]$Groups,
            [string]  $Source
        )

        $newTagCount = 0

        foreach ($grp in $Groups) {
            $grpName     = if ($grp.PSObject.Properties['display_name']) { $grp.display_name } else { $grp.id }
            $expressions = if ($grp.PSObject.Properties['expression'])   { $grp.expression   } else { @() }

            foreach ($expr in $expressions) {
                # Flatten NestedExpression so we always inspect plain Conditions
                $toInspect = [System.Collections.Generic.List[object]]::new()
                $resType   = if ($expr.PSObject.Properties['resource_type']) { $expr.resource_type } else { '' }

                if ($resType -eq 'NestedExpression') {
                    $inner = if ($expr.PSObject.Properties['expressions']) { $expr.expressions } else { @() }
                    foreach ($ie in $inner) { $toInspect.Add($ie) }
                } else {
                    $toInspect.Add($expr)
                }

                foreach ($e in $toInspect) {
                    $eType      = if ($e.PSObject.Properties['resource_type']) { $e.resource_type } else { '' }
                    $key        = if ($e.PSObject.Properties['key'])           { $e.key           } else { '' }
                    $memberType = if ($e.PSObject.Properties['member_type'])   { $e.member_type   } else { 'Unknown' }

                    if ($eType -ne 'Condition' -or $key -ne 'Tag') { continue }

                    $tagValue = if ($e.PSObject.Properties['value']) { $e.value } else { '' }
                    if (-not $tagValue) { continue }

                    if (-not $inUse[$tagValue]) {
                        $inUse[$tagValue] = @()
                        $newTagCount++
                    }
                    # Annotate with member_type and source so warnings downstream
                    # show exactly what kind of condition is keeping the tag alive
                    # and whether it came from the CSV or the live API
                    $inUse[$tagValue] += "$grpName [member_type=$memberType] [source=$Source]"
                }
            }
        }

        return $newTagCount
    }

    # =========================================================================
    # PHASE 1 — CSV scan (always runs)
    # =========================================================================
    Write-Host "  [TagCheck] Get-NSXTagsInUse v1.0.0" -ForegroundColor Cyan
    Write-Host "  [TagCheck] Phase 1: Scanning exported groups CSV..." -ForegroundColor Cyan

    if (-not (Test-Path $GroupsCsv)) {
        Write-Host "  [TagCheck] WARNING: Groups CSV not found at '$GroupsCsv' — Phase 1 skipped." -ForegroundColor Yellow
    } else {
        $csvRows    = Import-Csv -Path $GroupsCsv
        $csvObjects = [System.Collections.Generic.List[object]]::new()

        foreach ($row in $csvRows) {
            try {
                $csvObjects.Add(($row.RawJson | ConvertFrom-Json))
            } catch {
                Write-Host "  [TagCheck] Could not parse RawJson for group '$($row.Id)': $_" -ForegroundColor Yellow
            }
        }

        $csvFound = Invoke-GroupScan -Groups $csvObjects.ToArray() -Source 'csv'
        Write-Host ("  [TagCheck] Phase 1 complete: $(@($csvRows).Count) group(s) scanned from CSV, " +
                    "$csvFound unique tag value(s) found.") -ForegroundColor Cyan
    }

    # =========================================================================
    # PHASE 2 — Live API scan of system-owned groups only (optional)
    # =========================================================================
    if (-not $NSXManager) {
        Write-Host ("  [TagCheck] Phase 2 skipped: -NSXManager not provided. " +
                    "System-owned groups will NOT be checked.") -ForegroundColor Yellow
        Write-Host ("  [TagCheck] NOTE: This is safe if no system-owned groups use " +
                    "member_type=Group Tag conditions (the common case).") -ForegroundColor Yellow
    } else {
        Write-Host "  [TagCheck] Phase 2: Fetching system-owned groups from live API..." -ForegroundColor Cyan
        Write-Host "  [TagCheck] Target: $NSXManager / domain: $DomainId" -ForegroundColor Cyan

        $sysGroups  = [System.Collections.Generic.List[object]]::new()
        $cursor     = $null
        $pageNumber = 0
        $apiFailed  = $false

        do {
            # _system_owned=true filters server-side — only fetches the small
            # set of built-in NSX groups, not the full group inventory
            $url = ("https://$NSXManager/policy/api/v1/infra/domains/$DomainId/groups" +
                    "?_system_owned=true")
            if ($cursor) { $url += "&cursor=$cursor" }

            try {
                $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $Headers
            } catch {
                Write-Host "  [TagCheck] WARNING: Phase 2 API call failed — $_" -ForegroundColor Yellow
                Write-Host ("  [TagCheck] Proceeding with CSV results only. " +
                            "System-owned groups were NOT checked.") -ForegroundColor Yellow
                $apiFailed = $true
                break
            }

            $pageNumber++
            $pageGroups = if ($resp.PSObject.Properties['results']) { $resp.results } else { @() }
            foreach ($g in $pageGroups) { $sysGroups.Add($g) }
            $cursor = if ($resp.PSObject.Properties['cursor']) { $resp.cursor } else { $null }

        } while ($cursor)

        if (-not $apiFailed) {
            $sysFound = Invoke-GroupScan -Groups $sysGroups.ToArray() -Source 'system'
            Write-Host ("  [TagCheck] Phase 2 complete: $($sysGroups.Count) system-owned group(s) " +
                        "scanned across $pageNumber page(s), " +
                        "$sysFound additional unique tag value(s) found.") -ForegroundColor Cyan
        }
    }

    # =========================================================================
    # Summary
    # =========================================================================
    Write-Host "  [TagCheck] Total: $($inUse.Count) unique tag value(s) in use across all sources." -ForegroundColor Cyan

    if ($inUse.Count -gt 0) {
        Write-Host "  [TagCheck] Tags in use:" -ForegroundColor Yellow
        foreach ($k in ($inUse.Keys | Sort-Object)) {
            Write-Host "    '$k'  →  $($inUse[$k] -join ' | ')" -ForegroundColor Yellow
        }
    }

    return $inUse
}

# ============================================================
# Test-LGThinQConnection.ps1
# Tests connectivity with the official LG ThinQ Connect API
# Docs: https://thinq.developer.lge.com/en/cloud/docs/thinq-connect
# PAT:  https://connect-pat.lgthinq.com
# ============================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$Token = $env:LGTHINQ_TOKEN,       # Personal Access Token (PAT)

    [Parameter(Mandatory = $false)]
    [string]$CountryCode = "NL",               # Your two-letter country code

    [Parameter(Mandatory = $false)]
    [string]$ClientId = [System.Guid]::NewGuid().ToString()  # UUID per-client
)

# Regional base URLs:
#   Europe (NL, GB, DE, FR...): https://api-eic.lgthinq.com
#   North America:              https://api-na.lgthinq.com
#   Asia/Korea:                 https://api-ap.lgthinq.com
$BaseUrl = "https://api-eic.lgthinq.com"

# ── Validate inputs ────────────────────────────────────────
Write-Host "`n=== LG ThinQ Connect API Test ===" -ForegroundColor Cyan
Write-Host "Base URL    : $BaseUrl"
Write-Host "Country     : $CountryCode"
Write-Host "Client ID   : $ClientId`n"

if (-not $Token) {
    Write-Host "[ERROR] No token provided. Pass -Token or set `$env:LGTHINQ_TOKEN." -ForegroundColor Red
    Write-Host "        Get a PAT at: https://connect-pat.lgthinq.com" -ForegroundColor Yellow
    exit 1
}

$Headers = @{
    "Authorization"  = "Bearer $Token"
    "x-message-id"  = [System.Guid]::NewGuid().ToString()   # Unique per request
    "x-client-id"   = $ClientId
    "x-country"     = $CountryCode
    "x-api-key"     = "v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3"   # Public key from LG docs
    "Accept"        = "application/json"
    "Content-Type"  = "application/json"
}

# ── Helper ─────────────────────────────────────────────────
function Write-TestResult {
    param([string]$Name, [bool]$Success, [string]$Detail = "")
    $icon  = if ($Success) { "[PASS]" } else { "[FAIL]" }
    $color = if ($Success) { "Green" } else { "Red" }
    Write-Host "$icon $Name" -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Gray }
}

function Invoke-ThinQ {
    param([string]$Uri, [string]$Method = "GET")
    # Refresh message-id per call
    $Headers["x-message-id"] = [System.Guid]::NewGuid().ToString()
    try {
        $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -TimeoutSec 15 -ErrorAction Stop
        return @{ Success = $true; Data = $response; StatusCode = 200 }
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        $body = $null
        try { $body = $_.ErrorDetails.Message | ConvertFrom-Json } catch {}
        return @{ Success = $false; Data = $body; StatusCode = $code; Error = $_.Exception.Message }
    }
}

# ── Step 1: GET /devices ───────────────────────────────────
Write-Host "── Step 1: Device List ────────────────────────────────"
$result = Invoke-ThinQ -Uri "$BaseUrl/devices"

if ($result.Success) {
    $devices = $result.Data.response
    $count   = ($devices | Measure-Object).Count
    Write-TestResult "GET /devices" $true "$count device(s) returned"

    if ($count -gt 0) {
        Write-Host "`n  Registered devices:" -ForegroundColor Cyan
        foreach ($d in $devices) {
            $alias = if ($d.deviceInfo.alias) { $d.deviceInfo.alias } else { $d.deviceId }
            $type  = $d.deviceInfo.deviceType
            Write-Host "    • $alias  |  type: $type  |  id: $($d.deviceId)" -ForegroundColor White
        }
    } else {
        Write-Host "  (No devices found — check your PAT's Scope Of Authority)" -ForegroundColor Yellow
    }
} else {
    Write-TestResult "GET /devices" $false "HTTP $($result.StatusCode) – $($result.Error)"
    if ($result.StatusCode -eq 401) {
        Write-Host "  → Token invalid or expired. Renew at https://connect-pat.lgthinq.com" -ForegroundColor Yellow
    } elseif ($result.StatusCode -eq 403) {
        Write-Host "  → Token lacks permission. Ensure the correct scopes are enabled for your PAT." -ForegroundColor Yellow
    }
    if ($result.Data) {
        Write-Host "  API response: $($result.Data | ConvertTo-Json -Depth 3)" -ForegroundColor DarkGray
    }
}

# ── Step 2: GET /devices/{id}/profile (first device) ──────
Write-Host "`n── Step 2: Device Profile (first device) ──────────────"
if ($result.Success -and ($result.Data.response | Measure-Object).Count -gt 0) {
    $firstId     = $result.Data.response[0].deviceId
    $profResult  = Invoke-ThinQ -Uri "$BaseUrl/devices/$firstId/profile"

    if ($profResult.Success) {
        Write-TestResult "GET /devices/{id}/profile" $true "Profile retrieved for $firstId"
        $profileKeys = ($profResult.Data.response.property.PSObject.Properties.Name) -join ", "
        Write-Host "       Profile properties: $profileKeys" -ForegroundColor Gray
    } else {
        Write-TestResult "GET /devices/{id}/profile" $false "HTTP $($profResult.StatusCode) – $($profResult.Error)"
    }
} else {
    Write-Host "  [SKIP] No device available to test profile endpoint" -ForegroundColor Yellow
}

# ── Step 3: GET /devices/{id}/state (first device) ────────
Write-Host "`n── Step 3: Device State (first device) ────────────────"
if ($result.Success -and ($result.Data.response | Measure-Object).Count -gt 0) {
    $firstId    = $result.Data.response[0].deviceId
    $stateResult = Invoke-ThinQ -Uri "$BaseUrl/devices/$firstId/state"

    if ($stateResult.Success) {
        Write-TestResult "GET /devices/{id}/state" $true "State retrieved for $firstId"
    } else {
        Write-TestResult "GET /devices/{id}/state" $false "HTTP $($stateResult.StatusCode) – $($stateResult.Error)"
    }
} else {
    Write-Host "  [SKIP] No device available to test state endpoint" -ForegroundColor Yellow
}

Write-Host "`n=== Test Complete ===`n" -ForegroundColor Cyan
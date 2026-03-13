# ============================================================
#  Test-GoodWeSEMS.ps1
#  Tests the GoodWe SEMS / SEMSPlus API connection
# ============================================================

param(
    [string]$Email      = "",
    [string]$Password   = "",
    [string]$StationId  = ""
)

# ── Prompt for credentials if not supplied ──────────────────
if (-not $Email)     { $Email     = Read-Host "SEMS e-mailadres" }
if (-not $Password)  { $Password  = Read-Host "SEMS wachtwoord" -AsSecureString | ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) } }
if (-not $StationId) { $StationId = Read-Host "Station ID (optioneel, Enter om over te slaan)" }

function Write-Step { param($Text) Write-Host ""; Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan; Write-Host "  $Text" -ForegroundColor Cyan; Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan }
function Write-Ok    { param($Text) Write-Host "  ✓ $Text" -ForegroundColor Green }
function Write-Warn  { param($Text) Write-Host "  ⚠ $Text" -ForegroundColor Yellow }
function Write-Fail  { param($Text) Write-Host "  ✗ $Text" -ForegroundColor Red }
function Write-Info  { param($Text) Write-Host "  $Text" -ForegroundColor Gray }

# ── MD5 hash helper ─────────────────────────────────────────
function Get-MD5Hash {
    param([string]$Text)
    $Bytes  = [Text.Encoding]::UTF8.GetBytes($Text)
    $Hash   = [Security.Cryptography.MD5]::Create().ComputeHash($Bytes)
    return ($Hash | ForEach-Object { $_.ToString("x2") }) -join ""
}

# ── POST helper ─────────────────────────────────────────────
function Invoke-SemsPost {
    param(
        [string]$Url,
        [string]$TokenHeader,
        [hashtable]$Body
    )
    try {
        $Response = Invoke-RestMethod `
            -Uri         $Url `
            -Method      POST `
            -Headers     @{ Token = $TokenHeader } `
            -ContentType "application/json" `
            -Body        ($Body | ConvertTo-Json -Compress) `
            -TimeoutSec  15
        return $Response
    } catch {
        return $null
    }
}

# ════════════════════════════════════════════════════════════
#  STEP 1 — Try login on both portals
# ════════════════════════════════════════════════════════════
Write-Step "STEP 1: Login pogingen"

$Portals = @(
    @{ Name = "semsportal.com (oud)";  Host = "www.semsportal.com";   Client = "ios" },
    @{ Name = "semsplus.goodwe.com (nieuw)"; Host = "semsplus.goodwe.com"; Client = "web" }
)

$Auth = $null
$SuccessPortal = $null

foreach ($Portal in $Portals) {
    Write-Info "Probeer $($Portal.Name)..."

    $EmptyToken = @{ version = "v2.1.0"; client = $Portal.Client; language = "en" } | ConvertTo-Json -Compress

    # Try MD5 password first, then plain text
    foreach ($PwdVariant in @("md5", "plain")) {
        $Pwd = if ($PwdVariant -eq "md5") { Get-MD5Hash $Password } else { $Password }
        $PwdLabel = if ($PwdVariant -eq "md5") { "MD5" } else { "plain text" }

        $Res = Invoke-SemsPost `
            -Url         "https://$($Portal.Host)/api/v1/Common/CrossLogin" `
            -TokenHeader $EmptyToken `
            -Body        @{ account = $Email; pwd = $Pwd }

        if ($Res -and $Res.data -and $Res.data.token) {
            Write-Ok "Ingelogd via $($Portal.Name) met $PwdLabel wachtwoord"
            $Auth = $Res.data
            $Auth | Add-Member -NotePropertyName "portal_host" -NotePropertyValue $Portal.Host -Force
            $Auth | Add-Member -NotePropertyName "client_type" -NotePropertyValue $Portal.Client -Force
            $SuccessPortal = $Portal.Name
            break
        } else {
            $ErrMsg = if ($Res) { $Res.msg } else { "geen response" }
            Write-Info "  → $PwdLabel mislukt: $ErrMsg"
        }
    }

    if ($Auth) { break }
}

if (-not $Auth) {
    Write-Fail "Login mislukt op alle portals."
    Write-Host ""
    Write-Host "  Mogelijke oorzaken:" -ForegroundColor White
    Write-Host "    - Verkeerd e-mailadres of wachtwoord"
    Write-Host "    - Account staat op een regionaal portal (CN/AU/etc)"
    Write-Host "    - Account is vergrendeld na meerdere mislukte pogingen"
    exit 1
}

Write-Host ""
Write-Info "Token    : $($Auth.token.Substring(0, [Math]::Min(20, $Auth.token.Length)))..."
Write-Info "UID      : $($Auth.uid)"
Write-Info "API base : $($Auth.api)"

# Determine API base URL
$ApiBase = if ($Auth.api) { $Auth.api.TrimEnd('/') } else { "https://$($Auth.portal_host)" }
$AuthToken = @{
    version   = "v2.1.0"
    client    = $Auth.client_type
    language  = "en"
    token     = $Auth.token
    uid       = $Auth.uid
    timestamp = $Auth.timestamp
} | ConvertTo-Json -Compress

# ════════════════════════════════════════════════════════════
#  STEP 2 — List power stations
# ════════════════════════════════════════════════════════════
Write-Step "STEP 2: Installaties ophalen"

$StationsRes = Invoke-SemsPost `
    -Url         "$ApiBase/api/v2/PowerStation/GetPowerStationList" `
    -TokenHeader $AuthToken `
    -Body        @{ page_size = 20; page_index = 1 }

if (-not $StationsRes -or -not $StationsRes.data) {
    Write-Warn "Geen installaties gevonden of fout bij ophalen."
    Write-Info "Raw response: $($StationsRes | ConvertTo-Json)"
} else {
    $Stations = $StationsRes.data.list
    if (-not $Stations -or $Stations.Count -eq 0) {
        Write-Warn "Geen installaties in je account."
    } else {
        Write-Ok "$($Stations.Count) installatie(s) gevonden:"
        Write-Host ""
        Write-Host ("  {0,-40} {1,-15} {2}" -f "Station ID", "Capaciteit", "Naam") -ForegroundColor White
        Write-Host "  ──────────────────────────────────────────────────────────────"
        foreach ($Station in $Stations) {
            Write-Host ("  {0,-40} {1,-15} {2}" -f $Station.id, "$($Station.capacity) kWp", $Station.stationname)
        }

        # Auto-fill StationId if not provided and only one station
        if (-not $StationId -and $Stations.Count -eq 1) {
            $StationId = $Stations[0].id
            Write-Host ""
            Write-Ok "Station ID automatisch ingevuld: $StationId"
        } elseif (-not $StationId) {
            Write-Host ""
            Write-Warn "Meerdere installaties gevonden. Geef het Station ID mee als parameter om maanddata op te halen."
            Write-Info "Gebruik: .\Test-GoodWeSEMS.ps1 -Email '...' -Password '...' -StationId '<ID hierboven>'"
        }
    }
}

# ════════════════════════════════════════════════════════════
#  STEP 3 — Monthly data (if StationId known)
# ════════════════════════════════════════════════════════════
if ($StationId) {
    Write-Step "STEP 3: Maandelijkse data voor station $StationId"

    $CurrentYear = (Get-Date).Year

    foreach ($Year in @($CurrentYear - 1, $CurrentYear)) {
        Write-Host ""
        Write-Host "  ── $Year ──────────────────────────────────────" -ForegroundColor White

        $MonthRes = Invoke-SemsPost `
            -Url         "$ApiBase/api/v2/PowerStation/GetPowerStationByMonth" `
            -TokenHeader $AuthToken `
            -Body        @{ powerStationId = $StationId; count = "12"; date = "$Year-01-01" }

        if (-not $MonthRes -or -not $MonthRes.data -or -not $MonthRes.data.month) {
            Write-Warn "Geen maanddata voor $Year (response: $($MonthRes.msg))"

            # Try fallback chart endpoint
            Write-Info "Probeer fallback (GetChartByPlant)..."
            $ChartRes = Invoke-SemsPost `
                -Url         "$ApiBase/api/v2/Charts/GetChartByPlant" `
                -TokenHeader $AuthToken `
                -Body        @{ plantuid = $StationId; count = "12"; date = "$Year-01-01"; chartIndexId = "2"; USD = "1" }

            if ($ChartRes -and $ChartRes.data -and $ChartRes.data.lines) {
                Write-Ok "Fallback gelukt. Beschikbare lijnen:"
                foreach ($Line in $ChartRes.data.lines) {
                    Write-Info "  key=$($Line.key)  punten=$($Line.xy.Count)"
                }
            } else {
                Write-Fail "Ook fallback geeft geen data: $($ChartRes.msg)"
            }
        } else {
            $Months = $MonthRes.data.month
            $HasSell = $Months | Where-Object { $_.eSell -and $_.eSell -gt 0 }

            Write-Host ("  {0,-8} {1,-14} {2,-14} {3}" -f "Maand", "Opgewekt (kWh)", "Teruglev. (kWh)", "Velden aanwezig") -ForegroundColor White
            Write-Host "  ────────────────────────────────────────────────────"

            $Months | ForEach-Object -Begin { $i = 1 } -Process {
                $Fields = ($_ | Get-Member -MemberType NoteProperty).Name -join ", "
                $Opgewekt = if ($_.eMonth -ne $null) { "{0:N2}" -f $_.eMonth } else { "null" }
                $Terug    = if ($_.eSell  -ne $null) { "{0:N2}" -f $_.eSell  } else { "null" }
                $Color    = if ($_.eSell -gt 0) { "Green" } elseif ($_.eMonth -gt 0) { "White" } else { "DarkGray" }
                Write-Host ("  {0,-8} {1,-14} {2,-14} {3}" -f "$Year-$('{0:D2}' -f $i)", $Opgewekt, $Terug, $Fields) -ForegroundColor $Color
                $i++
            }

            Write-Host ""
            if ($HasSell) {
                Write-Ok "eSell (teruglevering) aanwezig in de data ✓"
            } else {
                Write-Warn "eSell is overal 0 of null — teruglevering wordt niet gemeten via dit endpoint"
                Write-Info "Mogelijk meet jouw omvormer het niet, of staat 'feed-in' niet ingeschakeld in SEMS."
            }
        }
    }
} else {
    Write-Host ""
    Write-Warn "STEP 3 overgeslagen — geen Station ID beschikbaar."
}

# ════════════════════════════════════════════════════════════
#  Summary
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  Samenvatting" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""
Write-Ok  "Portal  : $SuccessPortal"
Write-Ok  "API     : $ApiBase"
if ($StationId) { Write-Ok "Station : $StationId" }
Write-Host ""
Write-Host "  Gebruik deze waarden in de dashboard instellingen." -ForegroundColor White
Write-Host ""
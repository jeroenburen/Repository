# ============================================================
#  Test-TibberAPI.ps1
#  Tests the Tibber GraphQL API for consumption and production
# ============================================================

param(
    [string]$Token = "",
    [int]$Year = 0          # e.g. -Year 2023  (0 = show all available data)
)

# ── Prompt for token if not supplied ────────────────────────
if (-not $Token) {
    $Token = Read-Host "Paste your Tibber API token"
}
if (-not $Token) {
    Write-Host "No token provided. Exiting." -ForegroundColor Red
    exit 1
}

# ── Prompt for year if not supplied ─────────────────────────
if ($Year -eq 0) {
    $YearInput = Read-Host "Enter year to query (e.g. 2023), or press Enter for all available data"
    if ($YearInput -match '^\d{4}$') { $Year = [int]$YearInput }
}
$YearLabel = if ($Year -gt 0) { "year $Year" } else { "all available data" }

$ApiUrl = "https://api.tibber.com/v1-beta/gql"

# ── Helper: call the GraphQL API ────────────────────────────
function Invoke-TibberQuery {
    param([string]$Query)

    $Body = @{ query = $Query } | ConvertTo-Json -Compress

    $Response = Invoke-RestMethod `
        -Uri        $ApiUrl `
        -Method     POST `
        -Headers    @{ Authorization = "Bearer $Token" } `
        -ContentType "application/json" `
        -Body       $Body

    if ($Response.errors) {
        $Msg = $Response.errors[0].message
        Write-Host "GraphQL error: $Msg" -ForegroundColor Red
        exit 1
    }
    return $Response.data
}

# ── Helper: fetch all pages of consumption data ──────────────
# Uses cursor-based pagination via pageInfo.
# Pages backwards from most-recent, 12 months at a time.
# Stops when hasPreviousPage is false, or when results go
# before the requested year (early-exit optimisation).
function Get-AllConsumptionNodes {
    param([int]$FilterYear = 0)

    $PageSize = 12
    $AllNodes = @()
    $Before   = $null   # cursor; null = start from most-recent page

    Write-Host "  Fetching consumption pages..." -ForegroundColor DarkGray

    do {
        $CursorArg = if ($Before) { ", before: `"$Before`"" } else { "" }
        $Query = @"
{
  viewer {
    homes {
      consumption(resolution: MONTHLY, last: $PageSize$CursorArg) {
        pageInfo { hasPreviousPage startCursor }
        nodes { from to consumption cost currency }
      }
    }
  }
}
"@
        $Data     = Invoke-TibberQuery -Query $Query
        $Page     = $Data.viewer.homes[0].consumption
        $Nodes    = $Page.nodes
        $PageInfo = $Page.pageInfo

        Write-Host "    Got $($Nodes.Count) node(s); hasPreviousPage=$($PageInfo.hasPreviousPage)" -ForegroundColor DarkGray

        $AllNodes = $Nodes + $AllNodes   # prepend to keep chronological order

        # Early exit: oldest node on this page is before the requested year
        $OldestNode = $Nodes | Where-Object { $_.from } | Select-Object -First 1
        if ($FilterYear -gt 0 -and $OldestNode) {
            if ([datetime]::Parse($OldestNode.from).Year -lt $FilterYear) { break }
        }

        $Before = $PageInfo.startCursor

    } while ($PageInfo.hasPreviousPage)

    if ($FilterYear -gt 0) {
        $AllNodes = $AllNodes | Where-Object { $_.from -and [datetime]::Parse($_.from).Year -eq $FilterYear }
    }

    return $AllNodes
}

# ── Helper: fetch all pages of production data ───────────────
function Get-AllProductionNodes {
    param([int]$FilterYear = 0)

    $PageSize = 12
    $AllNodes = @()
    $Before   = $null

    Write-Host "  Fetching production pages..." -ForegroundColor DarkGray

    do {
        $CursorArg = if ($Before) { ", before: `"$Before`"" } else { "" }
        $Query = @"
{
  viewer {
    homes {
      production(resolution: MONTHLY, last: $PageSize$CursorArg) {
        pageInfo { hasPreviousPage startCursor }
        nodes { from to production profit currency }
      }
    }
  }
}
"@
        $Data     = Invoke-TibberQuery -Query $Query
        $Page     = $Data.viewer.homes[0].production
        $Nodes    = $Page.nodes
        $PageInfo = $Page.pageInfo

        Write-Host "    Got $($Nodes.Count) node(s); hasPreviousPage=$($PageInfo.hasPreviousPage)" -ForegroundColor DarkGray

        $AllNodes = $Nodes + $AllNodes

        $OldestNode = $Nodes | Where-Object { $_.from } | Select-Object -First 1
        if ($FilterYear -gt 0 -and $OldestNode) {
            if ([datetime]::Parse($OldestNode.from).Year -lt $FilterYear) { break }
        }

        $Before = $PageInfo.startCursor

    } while ($PageInfo.hasPreviousPage)

    if ($FilterYear -gt 0) {
        $AllNodes = $AllNodes | Where-Object { $_.from -and [datetime]::Parse($_.from).Year -eq $FilterYear }
    }

    return $AllNodes
}

# ════════════════════════════════════════════════════════════
#  STEP 1 — Verify token and show home info
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  STEP 1: Account & home info" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

$InfoQuery = @"
{
  viewer {
    name
    login
    homes {
      id
      address { address1, postalCode, city }
      features { realTimeConsumptionEnabled }
      meteringPointData { consumptionEan, gridCompany }
    }
  }
}
"@

$Info   = Invoke-TibberQuery -Query $InfoQuery
$Viewer = $Info.viewer
Write-Host "  Name  : $($Viewer.name)" -ForegroundColor Green
Write-Host "  Login : $($Viewer.login)" -ForegroundColor Green

foreach ($TibberHome in $Viewer.homes) {
    Write-Host ""
    Write-Host "  Home ID : $($TibberHome.id)" -ForegroundColor Yellow
    Write-Host "  Address : $($TibberHome.address.address1), $($TibberHome.address.postalCode) $($TibberHome.address.city)"
    Write-Host "  Grid    : $($TibberHome.meteringPointData.gridCompany)"
    Write-Host "  EAN     : $($TibberHome.meteringPointData.consumptionEan)"
    Write-Host "  Realtime: $($TibberHome.features.realTimeConsumptionEnabled)"
}

# ════════════════════════════════════════════════════════════
#  STEP 2 — Monthly consumption
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  STEP 2: Monthly consumption ($YearLabel)" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

$CNodes = Get-AllConsumptionNodes -FilterYear $Year

if (-not $CNodes -or $CNodes.Count -eq 0) {
    Write-Host "  No consumption data returned for $YearLabel." -ForegroundColor Yellow
} else {
    Write-Host ("  {0,-12} {1,-12} {2,-10} {3}" -f "Month", "kWh", "Cost", "Currency") -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────"
    foreach ($Node in $CNodes) {
        if ($null -eq $Node.from) { continue }
        $Date = [datetime]::Parse($Node.from).ToString("yyyy-MM")
        Write-Host ("  {0,-12} {1,-12:N2} {2,-10:N2} {3}" -f $Date, $Node.consumption, $Node.cost, $Node.currency)
    }
    Write-Host ""
    $TotalKwh  = ($CNodes | Where-Object { $_.consumption } | Measure-Object -Property consumption -Sum).Sum
    $TotalCost = ($CNodes | Where-Object { $_.cost }        | Measure-Object -Property cost        -Sum).Sum
    Write-Host ("  Total: {0:N0} kWh  /  {1:N2} {2}" -f $TotalKwh, $TotalCost, $CNodes[-1].currency) -ForegroundColor Green
}

# ════════════════════════════════════════════════════════════
#  STEP 3 — Monthly production / feed-in (teruglevering)
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  STEP 3: Monthly production / feed-in ($YearLabel)" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

$PNodes = Get-AllProductionNodes -FilterYear $Year

if (-not $PNodes -or $PNodes.Count -eq 0) {
    Write-Host ""
    Write-Host "  ⚠  No production data returned." -ForegroundColor Yellow
    Write-Host "     This means Tibber does not track feed-in for your connection." -ForegroundColor DarkYellow
    Write-Host "     Teruglevering will need to come from GoodWe instead." -ForegroundColor DarkYellow
} else {
    $HasRealData = $PNodes | Where-Object { $_.production -and $_.production -gt 0 }

    if (-not $HasRealData) {
        Write-Host ""
        Write-Host "  ⚠  Production nodes exist but all values are null or 0." -ForegroundColor Yellow
        Write-Host "     Tibber is aware of production but has no measured data." -ForegroundColor DarkYellow
        Write-Host "     Teruglevering will need to come from GoodWe instead." -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "  Raw nodes:" -ForegroundColor Gray
        $PNodes | Format-Table from, to, production, profit, currency -AutoSize
    } else {
        Write-Host ("  {0,-12} {1,-12} {2,-10} {3}" -f "Month", "kWh fed in", "Profit", "Currency") -ForegroundColor White
        Write-Host "  ─────────────────────────────────────────"
        foreach ($Node in $PNodes) {
            if ($null -eq $Node.from) { continue }
            $Date = [datetime]::Parse($Node.from).ToString("yyyy-MM")
            Write-Host ("  {0,-12} {1,-12:N2} {2,-10:N2} {3}" -f $Date, $Node.production, $Node.profit, $Node.currency)
        }
        Write-Host ""
        $TotalProd   = ($PNodes | Where-Object { $_.production } | Measure-Object -Property production -Sum).Sum
        $TotalProfit = ($PNodes | Where-Object { $_.profit }     | Measure-Object -Property profit     -Sum).Sum
        Write-Host ("  Total: {0:N0} kWh fed in  /  {1:N2} {2} profit" -f $TotalProd, $TotalProfit, $PNodes[-1].currency) -ForegroundColor Green
    }
}

# ════════════════════════════════════════════════════════════
#  STEP 4 — Combined monthly overview (what the dashboard uses)
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  STEP 4: Combined view ($YearLabel)" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

# Reuse nodes already fetched in steps 2 & 3 — no extra API calls needed
$Months = @{}
foreach ($Node in $CNodes) {
    if ($null -eq $Node.from) { continue }
    $Key = [datetime]::Parse($Node.from).ToString("yyyy-MM")
    $Months[$Key] = @{ consumption = $Node.consumption; cost = $Node.cost; production = $null; profit = $null }
}
foreach ($Node in $PNodes) {
    if ($null -eq $Node.from) { continue }
    $Key = [datetime]::Parse($Node.from).ToString("yyyy-MM")
    if (-not $Months[$Key]) { $Months[$Key] = @{ consumption = $null; cost = $null } }
    $Months[$Key].production = $Node.production
    $Months[$Key].profit     = $Node.profit
}

Write-Host ("  {0,-12} {1,-12} {2,-12} {3,-12} {4}" -f "Month", "kWh used", "Cost (€)", "kWh fed in", "Profit (€)") -ForegroundColor White
Write-Host "  ────────────────────────────────────────────────────────"

foreach ($Key in ($Months.Keys | Sort-Object)) {
    $M    = $Months[$Key]
    $Used = if ($M.consumption) { "{0:N2}" -f $M.consumption } else { "-" }
    $Cost = if ($M.cost)        { "{0:N2}" -f $M.cost }        else { "-" }
    $Fed  = if ($M.production)  { "{0:N2}" -f $M.production }  else { "-" }
    $Prof = if ($M.profit)      { "{0:N2}" -f $M.profit }      else { "-" }
    Write-Host ("  {0,-12} {1,-12} {2,-12} {3,-12} {4}" -f $Key, $Used, $Cost, $Fed, $Prof)
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ""
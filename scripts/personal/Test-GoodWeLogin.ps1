#Requires -Version 5.1
<#
.SYNOPSIS
    Test GoodWe SEMSPlus login — alle vier methodes die de Energie Dashboard app probeert.

.DESCRIPTION
    Simuleert exact de loginvolgorde van server.js:
      1. eu.semsportal.com v2      (primair, geen x-signature, plain pwd)
      2. Classic semsportal.com    (MD5 + plain, werkt tot 30 mei 2026)
      3. Nieuw SEMSPlus portaal    (semsplus.goodwe.com, x-signature — kan c0602 geven)
      4. Oud SEMSPlus portaal      (semsplus.goodwe.com legacy, MD5 + plain)

    Bij succes toont het script het verkregen token, uid en API-base URL.

.PARAMETER Email
    Jouw GoodWe / SEMSPlus e-mailadres.

.PARAMETER Password
    Jouw GoodWe / SEMSPlus wachtwoord (plain text).

.EXAMPLE
    .\Test-GoodWeLogin.ps1 -Email "jouw@email.nl" -Password "jouwwachtwoord"

.EXAMPLE
    # Wachtwoord via prompt (verborgen invoer)
    .\Test-GoodWeLogin.ps1 -Email "jouw@email.nl"
#>

param(
    [Parameter(Mandatory)]
    [string]$Email,

    [Parameter()]
    [string]$Password
)

if (-not $Password) {
    $secPwd   = Read-Host "Wachtwoord" -AsSecureString
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPwd))
}

# ── Hulpfuncties ─────────────────────────────────────────────────────────────

function Get-MD5Hash([string]$text) {
    $md5   = [Security.Cryptography.MD5]::Create()
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Get-SHA256Hash([string]$text) {
    $sha   = [Security.Cryptography.SHA256]::Create()
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
}

function New-XSignature([string]$bodyJson) {
    $ts  = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $raw = "$(Get-SHA256Hash $bodyJson)@$ts"
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw))
}

function Invoke-SemsPost {
    param([string]$Url, [hashtable]$ExtraHeaders, [object]$Body)
    $json = $Body | ConvertTo-Json -Compress
    $hdrs = @{
        "Content-Type" = "application/json"
        "Accept"       = "application/json, text/plain, */*"
        "User-Agent"   = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"
        "Origin"       = "https://semsplus.goodwe.com"
        "Referer"      = "https://semsplus.goodwe.com/"
    }
    foreach ($k in $ExtraHeaders.Keys) { $hdrs[$k] = $ExtraHeaders[$k] }
    try {
        Invoke-RestMethod -Uri $Url -Method POST -Headers $hdrs -Body $json -ErrorAction Stop
    } catch {
        $sc = $_.Exception.Response.StatusCode.value__
        $eb = $null
        try { $eb = [IO.StreamReader]::new($_.Exception.Response.GetResponseStream()).ReadToEnd() } catch {}
        throw [Exception]::new("HTTP $sc$(if ($eb) { " — $eb" })")
    }
}

function Show-Success([string]$method, [object]$data) {
    Write-Host ""
    Write-Host "  ✅  SUCCES via $method" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ┌─ Login resultaat ──────────────────────────────────" -ForegroundColor Green
    Write-Host "  │  UID       : $($data.uid)"       -ForegroundColor White
    Write-Host "  │  Token     : $($data.token)"     -ForegroundColor White
    Write-Host "  │  Timestamp : $($data.timestamp)" -ForegroundColor White
    Write-Host "  │  API base  : $($data.api)"       -ForegroundColor White
    if ($data.region) { Write-Host "  │  Regio     : $($data.region)" -ForegroundColor White }
    Write-Host "  └────────────────────────────────────────────────────" -ForegroundColor Green
}

# ── Banner ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       GoodWe SEMSPlus — Login Test Script           ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Account : $Email"                              -ForegroundColor Gray
Write-Host "  Datum   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host ""

$success = $false
$md5pwd  = Get-MD5Hash $Password

# ════════════════════════════════════════════════════════════════════════════
# METHODE 1 — Classic semsportal.com  (primair, bewezen werkend)
# ════════════════════════════════════════════════════════════════════════════

Write-Host "── Methode 1: Classic semsportal.com ───────────────────" -ForegroundColor Yellow
$tkHdr1 = (@{ version = "v2.1.0"; client = "ios"; language = "en" } | ConvertTo-Json -Compress)

foreach ($a in @(
    [pscustomobject]@{ label="MD5";   pwd=$md5pwd   }
    [pscustomobject]@{ label="Plain"; pwd=$Password }
)) {
    Write-Host "  Poging : $($a.label)" -ForegroundColor DarkGray
    try {
        $r = Invoke-SemsPost "https://www.semsportal.com/api/v1/Common/CrossLogin" @{ Token=$tkHdr1 } @{ account=$Email; pwd=$a.pwd }
        if ($r.data -and $r.data.token) { Show-Success "Methode 1 — semsportal.com ($($a.label))" $r.data; $success=$true; break }
        else { Write-Host "  ⚠  Afgewezen: $($r.msg)" -ForegroundColor DarkYellow }
    } catch { Write-Host "  ✗  Fout: $_" -ForegroundColor Red }
}

# ════════════════════════════════════════════════════════════════════════════
# METHODE 2 — eu.semsportal.com v2 CrossLogin  (geen x-signature, plain pwd)
# Gedocumenteerd via reverse-engineering — werkend alternatief na 30 mei 2026.
# ════════════════════════════════════════════════════════════════════════════

if (-not $success) {
    Write-Host ""
    Write-Host "── Methode 2: eu.semsportal.com v2 (geen x-signature) ──" -ForegroundColor Yellow

    # Token header is base64-encoded JSON (niet als plain string)
    $tkHdr2 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        (@{ uid=""; timestamp=0; token=""; client="web"; version=""; language="en" } | ConvertTo-Json -Compress)
    ))

    foreach ($host2 in @("eu.semsportal.com", "www.semsportal.com")) {
        Write-Host "  Host   : $host2" -ForegroundColor DarkGray
        try {
            $r2 = Invoke-SemsPost "https://$host2/api/v2/common/crosslogin" @{ Token=$tkHdr2 } `
                    @{ account=$Email; pwd=$Password; agreement_agreement=0; is_local=$false }
            if (($r2.code -eq 0 -or $r2.hasError -eq $false) -and $r2.data -and $r2.data.token) {
                Show-Success "Methode 2 — $host2 v2" $r2.data
                $success = $true
                break
            } else {
                Write-Host "  ⚠  Afgewezen: code=$($r2.code) msg=$($r2.msg)" -ForegroundColor DarkYellow
            }
        } catch { Write-Host "  ✗  Fout: $_" -ForegroundColor Red }
    }
}

# ════════════════════════════════════════════════════════════════════════════
# METHODE 3 — Nieuw SEMSPlus portaal  (x-signature vereist — kan c0602 geven)
# ════════════════════════════════════════════════════════════════════════════

if (-not $success) {
    Write-Host ""
    Write-Host "── Methode 3: Nieuw SEMSPlus portaal (x-signature) ────" -ForegroundColor Yellow

    $tkHdr3  = (@{ uid=""; timestamp=0; token=""; client="semsPlusWeb"; version=""; language="nl" } | ConvertTo-Json -Compress)
    $body3   = [ordered]@{ account=$Email; pwd=$Password; agreement=1; isLocal=$false; isChinese=$false }
    $body3j  = $body3 | ConvertTo-Json -Compress
    $xSig    = New-XSignature $body3j
    Write-Host "  x-sig  : $xSig" -ForegroundColor DarkGray

    try {
        $r3 = Invoke-SemsPost "https://semsplus.goodwe.com/web/sems/sems-user/api/v1/auth/cross-login" `
                @{ token=$tkHdr3; currentlang="nl"; neutral="0"; "x-signature"=$xSig } $body3
        if ($r3.code -eq "00000" -and $r3.data -and $r3.data.token) {
            Show-Success "Methode 3 — SEMSPlus nieuw" $r3.data; $success=$true
        } else {
            Write-Host "  ⚠  Afgewezen: code=$($r3.code) — $($r3.description)" -ForegroundColor DarkYellow
            if ($r3.code -eq "c0602") {
                Write-Host "  ℹ  c0602 = ongeldige x-signature (geheime sleutel onbekend)" -ForegroundColor DarkCyan
            }
        }
    } catch { Write-Host "  ✗  Fout: $_" -ForegroundColor Red }
}

# ════════════════════════════════════════════════════════════════════════════
# METHODE 4 — Oud SEMSPlus portaal
# ════════════════════════════════════════════════════════════════════════════

if (-not $success) {
    Write-Host ""
    Write-Host "── Methode 4: Oud SEMSPlus portaal ────────────────────" -ForegroundColor Yellow
    $tkHdr4 = (@{ version="v2.1.0"; client="web"; language="en" } | ConvertTo-Json -Compress)

    foreach ($a in @(
        [pscustomobject]@{ label="MD5";   pwd=$md5pwd   }
        [pscustomobject]@{ label="Plain"; pwd=$Password }
    )) {
        Write-Host "  Poging : $($a.label)" -ForegroundColor DarkGray
        try {
            $r4 = Invoke-SemsPost "https://semsplus.goodwe.com/api/v1/Common/CrossLogin" @{ Token=$tkHdr4 } @{ account=$Email; pwd=$a.pwd }
            if ($r4.data -and $r4.data.token) { Show-Success "Methode 4 — SEMSPlus oud ($($a.label))" $r4.data; $success=$true; break }
            else { Write-Host "  ⚠  Afgewezen: $($r4.msg)" -ForegroundColor DarkYellow }
        } catch { Write-Host "  ✗  Fout: $_" -ForegroundColor Red }
    }
}

# ── Eindresultaat ─────────────────────────────────────────────────────────────

Write-Host ""
if ($success) {
    Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Login gelukt — de app zou moeten kunnen synchroniseren." -ForegroundColor Green
    Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Green
} else {
    Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host "  Alle methodes mislukt. Controleer e-mail / wachtwoord." -ForegroundColor Red
    Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Red
}
Write-Host ""
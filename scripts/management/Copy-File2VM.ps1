# ============================================================
#  Copy-FileToVM.ps1
#  Copies a local file into a VMware guest VM using VMware Tools
#  (no network required — uses VMware Guest File I/O API)
# ============================================================

# --- Load VMware PowerCLI (must be installed) ---------------
if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    Write-Error "VMware PowerCLI is not installed. Install it with: Install-Module VMware.PowerCLI"
    exit 1
}
Import-Module VMware.VimAutomation.Core -ErrorAction Stop

# ============================================================
#  CONFIGURATION — edit these defaults or leave blank to be
#  prompted at runtime.
# ============================================================
$vCenterServer  = ""          # e.g. "vcenter.local" or ESXi host IP
$vmName         = ""          # e.g. "MyWindowsVM"
$guestUser      = ""          # Guest OS username
$guestPassword  = ""          # Guest OS password (plain text here, or use SecureString below)
$guestDestPath  = ""          # Destination path inside the VM, e.g. "C:\Temp\"

# ============================================================
#  PROMPT FOR ANY MISSING VALUES
# ============================================================
if (-not $vCenterServer) { $vCenterServer = Read-Host "vCenter / ESXi host" }
if (-not $vmName)        { $vmName        = Read-Host "VM name" }
if (-not $guestUser)     { $guestUser     = Read-Host "Guest OS username" }
if (-not $guestDestPath) { $guestDestPath = Read-Host "Destination path inside the VM (e.g. C:\Temp\)" }

$securePass = if ($guestPassword) {
    ConvertTo-SecureString $guestPassword -AsPlainText -Force
} else {
    Read-Host "Guest OS password" -AsSecureString
}
$guestCred = New-Object System.Management.Automation.PSCredential($guestUser, $securePass)

# ============================================================
#  FILE PICKER — opens a standard Windows Open File dialog
# ============================================================
Add-Type -AssemblyName System.Windows.Forms

$openDialog = New-Object System.Windows.Forms.OpenFileDialog
$openDialog.Title       = "Select a file to copy to the VM"
$openDialog.Multiselect = $false
$openDialog.Filter      = "All files (*.*)|*.*"

$dialogResult = $openDialog.ShowDialog()

if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "No file selected. Exiting." -ForegroundColor Yellow
    exit 0
}

$localFilePath = $openDialog.FileName
$fileName      = Split-Path $localFilePath -Leaf

# Ensure destination path ends with a backslash (Windows guest assumed)
if (-not $guestDestPath.EndsWith("\") -and -not $guestDestPath.EndsWith("/")) {
    $guestDestPath = $guestDestPath + "\"
}
$fullGuestPath = $guestDestPath + $fileName

# ============================================================
#  CONNECT TO vCENTER / ESXi
# ============================================================
Write-Host "`nConnecting to $vCenterServer ..." -ForegroundColor Cyan
$viServer = Connect-VIServer -Server $vCenterServer -ErrorAction Stop

# ============================================================
#  GET THE VM OBJECT
# ============================================================
$vm = Get-VM -Name $vmName -ErrorAction Stop
Write-Host "Found VM: $($vm.Name)  [Power state: $($vm.PowerState)]" -ForegroundColor Cyan

if ($vm.PowerState -ne "PoweredOn") {
    Write-Error "VM '$vmName' is not powered on. VMware Tools requires the VM to be running."
    Disconnect-VIServer -Server $viServer -Confirm:$false
    exit 1
}

# ============================================================
#  COPY THE FILE
# ============================================================
Write-Host "`nCopying '$localFilePath'" -ForegroundColor Green
Write-Host "  --> [$vmName] $fullGuestPath" -ForegroundColor Green

Copy-VMGuestFile `
    -Source      $localFilePath `
    -Destination $fullGuestPath `
    -VM          $vm `
    -LocalToGuest `
    -GuestCredential $guestCred `
    -ErrorAction Stop

Write-Host "`nFile copied successfully!" -ForegroundColor Green

# ============================================================
#  DISCONNECT
# ============================================================
Disconnect-VIServer -Server $viServer -Confirm:$false
Write-Host "Disconnected from $vCenterServer." -ForegroundColor Cyan
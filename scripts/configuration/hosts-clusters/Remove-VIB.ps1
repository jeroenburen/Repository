[CmdletBinding(SupportsShouldProcess=$true)]
Param(
    [parameter(valuefrompipeline = $true, mandatory = $true,
        HelpMessage = "From which host do you want to remove the VIB")]
        [string]$VMHost
    )

Write-Host "Connecting to vCenter Server"
Connect-VIServer -Server p0018600.dnb.nl | Out-Null

$vib = "cisco-vem-v320-esx"
Write-Host "Removing vib $vib"
$esxcli = Get-EsxCli -VMHost $VMhost -V2
$vib = ($esxcli.software.vib.list.invoke() | where {$_.Vendor -eq "Cisco"}).Name
$param = $esxcli.software.vib.remove.CreateArgs()
$param.dryrun = $false
$param.vibname = $vib
$param.force = $false
$esxcli.software.vib.remove.Invoke($param)
Write-Host "Disconnecting from vCenter Server"
Disconnect-VIServer -Confirm:$false | Out-Null
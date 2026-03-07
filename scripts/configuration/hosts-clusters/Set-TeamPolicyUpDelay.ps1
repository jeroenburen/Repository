# This script sets the advanced setting for the Team Policy Up Delay on connected ESXi hosts in the FR datacenter.
# Requires the VMware PowerCLI module to be installed and connected to a vCenter Server.
# Requires the ESXi host to be specified.
# /Net/TeamPolicyUpDelay --int-value 300000
[CmdletBinding(SupportsShouldProcess=$true)]
Param(
    [parameter(valuefrompipeline = $true, mandatory = $true,
        HelpMessage = "In which cluster do you want to change the advanced setting?")]
        [string]$ClusterName
    )

$vCenter = "vcenter.example.com" # Replace with your vCenter Server address
$DatacenterName = "FR" # Replace with your datacenter name

Write-Host "Connecting to vCenter Server"
Connect-VIServer -Server $vCenter | Out-Null

$VMHosts = Get-Datacenter -Name $DatacenterName | Get-VMHost | ?{$_.ConnectionState -eq 'Connected'}

foreach ($VMHost in $VMhosts) {
  $CurrentUpDelay = Get-AdvancedSetting -Entity $VMHost -Name "Net.TeamPolicyUpDelay"
    Write-Host "Current Team Policy Up Delay for $($VMHost.Name): $($CurrentUpDelay.Value) ms"
    Set-AdvancedSetting -Entity $VMHost -Name "Net.TeamPolicyUpDelay" -Value 300000 -Confirm:$false
    $NewUpDelay = Get-AdvancedSetting -Entity $VMHost -Name "Net.TeamPolicyUpDelay"
    Write-Host "New Team Policy Up Delay for $($VMHost.Name): $($NewUpDelay.Value) ms"
}

Disconnect-VIServer -Confirm:$false | Out-Null
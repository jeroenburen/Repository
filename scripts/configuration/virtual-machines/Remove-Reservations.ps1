$vCenter = "gp-vc.ci.domain.com"
$Credentials = Get-Credential -Message "Please enter your username and password for $($vCenter)"
$CustomerList = ("Customer1","Customer2","Customer3")

# Connect to vCenter server...
Connect-VIServer -Server $vCenter -Credential $Credentials

# Get all the Resource Pools for every customer in the list of customers...
$ResourcePools = foreach ($Customer in $CustomerList) {Get-ResourcePool -Name $Customer*}

# Get all the VMs in the customer Resource Pools that have a CPU and/or memory reservation...
$VMsWithReservations = foreach ($ResourcePool in $ResourcePools) `
{
  Get-VM -Location $ResourcePool -PipelineVariable vm | `
  Get-VMResourceConfiguration | ?{$_.CpuReservationMhz -ne 0 -or $_.MemReservationMb -ne 0} | select @{N='VM';E={$vm.Name}}, CpuReservationMhz,MemReservationGB
}
#$VMsWithReservations| Format-Table -AutoSize

# Remove the reservations from the VM...
foreach ($vm in $VMsWithReservations) {Set-VMResourceConfiguration -MemReservationGB 0 -CpuReservationMhz 0}

# Disconnect from vCenter server...
Disconnect-VIServer
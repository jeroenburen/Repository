# Connect to vCenter server with your own credentials
Connect-VIServer -Server vc.domain.com

# Change the path to the downloaded offline bundle (with the latest VMware Tools)
$depot = "VMware-Tools-12.5.2-core-offline-depot-ESXi-all-24697584.zip"
$vib = "C:\Users\JeroenBuren\Downloads\" + $depot


# Get all datastores. The script assumes that all datastores are named after the host with the datastore1 extension
$datastores = Get-Datastore | ?{$_.name -like "*ssd"}
# Get all hosts
$hosts = Get-VMHost

# Do this for every datastore
foreach ($ds in $datastores) {
  # Create a drive for each datastore
  New-PSDrive -Location $ds -Name DS -PSProvider VimDatastore -Root "\"
  # Check if the Tools folder exists and create it when it does not exist
  if (!(Test-Path -Path DS:\vmtools)) {New-Item -Path DS:\vmtools -ItemType Directory}
  # Check if the bundle is already uploaded and copy it when needed
  if (!(Test-Path -Path DS:\vmtools\$depot)) {Copy-DatastoreItem -Item $vib -Destination DS:\vmtools}
  # Disconnect the datastore drive
  Remove-PSDrive -Name DS -Confirm:$false
}

# Do this for every host
foreach ($h in Get-VMHost) {
  # Create the ESXCli connection
  $esxcli = Get-EsxCli -VMHost $h -V2
  # Create the parameter variable
  $param = $esxcli.software.vib.install.CreateArgs()
  # Set the variable arguments
  $param.dryrun = $false
  $param.depot = "/vmfs/volumes/" + $h.name.Split(".")[0] + "-ssd/vmtools/VMware-Tools-12.5.2-core-offline-depot-ESXi-all-24697584.zip"
  # Install the offline bundle
  $esxcli.software.vib.install.Invoke($param)
}

Disconnect-VIServer

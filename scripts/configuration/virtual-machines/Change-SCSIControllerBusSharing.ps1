<#
.SYNOPSIS
    Perform steps to change the SCSI Bus Sharing mode of the SCSI Controller of a VM.
    This is required for VMs that are used for Microsoft clusters (MSCS) and use RDMs.
.DESCRIPTION
    Use this script to change the SCSI Bus Sharing Mode to Physical.
    This script assumes availability of the following modules:
    - VMware-PowerCli
.PARAMETER
    - No parameters
.EXAMPLE
    .\Change-SCSIControllerBusSharing.ps1
.NOTES
    Script name: Change-SCSIControllerBusSharing.ps1
    Author:      Jeroen Buren
    DateCreated: 17-01-2020
#>

####################################################################################
#                                                                                  #
# Functions                                                                        #
#                                                                                  #
####################################################################################

function Get-ScriptDirectory {
  $Invocation = (Get-Variable MyInvocation -Scope 1).Value
  Split-Path $Invocation.MyCommand.Path
}

function Log {
  param(
    [Parameter(Mandatory=$true)][String]$Message,
    [Parameter(Mandatory=$true)][ValidateSet("Info","Debug","Warn","Error")][String]$Type,
    [Parameter(Mandatory=$true)][ValidateSet("Console","LogFile","Both")][String]$OutputMode
  )

  $dateTimeString = Get-Date -Format "yyyy-MM-dd HH:mm:sszz"
  $output = ($dateTimeString + " " + $type.ToUpper() + " " + $message)
  if ($outputMode -eq "Console" -OR $outputMode -eq "Both") {
    Write-Host $output
  }
  if ($outputMode -eq "LogFile" -OR $outputMode -eq "Both") {
    try {
      Add-Content $logFile -Value $output -ErrorAction Stop
    }
    catch {
      Log ("Failed to write to log file: """ + $logFile + """.") -OutputMode Console -Type Error
      Log ("[" + $_.Exception.GetType().FullName + "] " + $_.Exception.Message) -OutputMode Console -Type Error
    }
  }
}

# Logfile
Set-Variable logFile ((Get-ScriptDirectory) + "\Change-SCSIControllerBusSharing.log") -Option Constant -ErrorAction SilentlyContinue

Log -Message "Script started" -Type Info -OutputMode LogFile
Log -Message "Importing CSV file with VMs" -Type Info -OutputMode Both
$vms = Import-Csv D:\Scripts\VMware\VMs\ClusterNodes.csv -Delimiter ","

# First, shutdown the AMS cluster nodes. This will trigger a failover to the WSN nodes.
# Then change the SCSI Controller Bus Sharing to Physical and start the VM.
Log -Message "Working on AMS cluster node VMs" -Type Info -OutputMode Both
foreach ($vm in ($vms | Where {$_.Datacenter -eq "AMS"})) {
  Log -Message "Shutting down $($vm.Name)" -Type Info -OutputMode Both
  Get-VM -Name $vm.Name | Shutdown-VMGuest -Confirm:$false
  do {Start-Sleep -Seconds 5} while ((Get-VM -Name $vm.Name).PowerState -ne 'PoweredOff')
  if ((Get-VM -Name $vm.Name).PowerState -eq 'PoweredOff') {
    Start-Sleep -Seconds 5 # Wait for another 5 seconds
    Log -Message "Changing Bus Sharing Mode on $($vm.Name)" -Type Info -OutputMode Both
    Get-VM -Name $vm.Name | Get-HardDisk -DiskType RawPhysical | Get-ScsiController | Set-ScsiController -BusSharingMode Physical -Confirm:$false
  }
  Log -Message "Starting $($vm.Name)" -Type Info -OutputMode Both
  Get-VM -Name $vm.Name | Start-VM
}

# Now wait because the resources need to be active on the WSN nodes.
Log -Message "AMS cluster node VMs are all done. Now wait until all resources are running on the WSN cluster node VMs" -Type Info -OutputMode Both
Pause

# Now shutdown the WSN cluster nodes. This will trigger a failover back to the AMS nodes.
# Then change the SCSI Controller Bus Sharing to Physical and start the VM.
Log -Message "Working on WSN cluster node VMs" -Type Info -OutputMode Both
foreach ($vm in ($vms | Where {$_.Datacenter -eq "WSN"})) {
  Log -Message "Shutting down $($vm.Name)" -Type Info -OutputMode Both
  Get-VM -Name $vm.Name | Shutdown-VMGuest -Confirm:$false
  do {Start-Sleep -Seconds 5} while ((Get-VM -Name $vm.Name).PowerState -ne 'PoweredOff')
  if ((Get-VM -Name $vm.Name).PowerState -eq 'PoweredOff') {
    Start-Sleep -Seconds 5
    Log -Message "Changing Bus Sharing Mode on $($vm.Name)" -Type Info -OutputMode Both
    Get-VM -Name $vm.Name | Get-HardDisk -DiskType RawPhysical | Get-ScsiController | Set-ScsiController -BusSharingMode Physical
  }
  Log -Message "Starting $($vm.Name)" -Type Info -OutputMode Both
  Get-VM -Name $vm.Name | Start-VM
}

Log -Message "Script ended" -Type Info -OutputMode LogFile

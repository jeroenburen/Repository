function Get-ScriptDirectory {
  $ScriptInvocation = (Get-Variable MyInvocation -Scope 1).Value
  Split-Path $ScriptInvocation.MyCommand.Path
}

function Log {

# This Function requires a variable $LogFile that must be declared in the main script.
# Set-Variable LogFile ((Get-ScriptDirectory) + "\mylogfile.log") -Option Constant -ErrorAction SilentlyContinue

  param(
    [parameter(mandatory=$true)][String]$Message,
    [parameter(mandatory=$true)][ValidateSet("Info","Warning","Error","Debug")][String]$Type,
    [parameter(mandatory=$true)][ValidateSet("Console","File","Both")][String]$OutputMode
  )
  $DateTimeString = Get-Date -Format "yyyy-MM-dd HH:mm:sszz"
  $Output = ($DateTimeString + " " + $Type.ToUpper() + " " + $Message)
  switch ($OutputMode) {
    "Console" {Write-Host $Output}
    "File" {
      try {
        Add-Content $LogFile -Value $Output -ErrorAction Stop
      }
      catch {
        Log ("Failed to write to log file: """ + $LogFile + """.") -OutputMode Console -Type Error
        Log ("[" + $_.Exception.GetType().FullName + "] " + $_.Exception.Message) -OutputMode Console -Type Error
      }
    }
    "Both" {
      Write-Host $Output
      try {
        Add-Content $LogFile -Value $Output -ErrorAction Stop
      }
      catch {
        Log ("Failed to write to log file: """ + $LogFile + """.") -OutputMode Console -Type Error
        Log ("[" + $_.Exception.GetType().FullName + "] " + $_.Exception.Message) -OutputMode Console -Type Error
      }
    }
  }
}

#Set variables
$vcenter = "vc.domain.com"
Set-Variable LogFile ((Get-ScriptDirectory) + "\Set-DRSWindowsGroups.log") -Option Constant -ErrorAction SilentlyContinue
$user = "svc@domain.com"
$pass = ""

#Tag and Rule parameters
$vmtag = "Windows"
$hosttag = "Windows"
$ruleName = "affinity-windows-rule"
$ruleEnable = $false

Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

Log -Message "Script started..." -Type Info -OutputMode File
Log -Message "Connecting to vCenter $vcenter..." -Type Info -OutputMode Both
Connect-VIServer $vcenter -user $user -pass $pass | Out-Null

$clusters = Get-Cluster -server $vcenter
Log -Message "Found $($clusters.count) cluster(s)..." -Type Info -OutputMode File

foreach ($cluster in $clusters) {
  Log -Message "Processing cluster $($cluster)..." -Type Info -OutputMode File
  $windowsHosts = @()
  $windowsVMs = @()

  #Initiate existence variables
  $vmTagExists = $false
  $hostGroupExists = $false
  $vmGroupExists = $false

  #Check if DRS groups exists
  $drsHostGroup = Get-DrsClusterGroup -Cluster $cluster -Type VMHostGroup -Name $hosttag-hostgrp -ErrorAction SilentlyContinue
  $drsVMGroup = Get-DrsClusterGroup -Cluster $cluster -Type VMGroup -Name $vmtag-vmgrp -ErrorAction SilentlyContinue
  if ($drsHostGroup) {
    Log -Message "DRS group for Windows hosts found..." -Type Info -OutputMode File
    $hostGroupExists = $true
  }
  if ($drsVMGroup) {
    Log -Message "DRS group for Windows VMs found..." -Type Info -OutputMode File
    $vmGroupExists = $true
  }

  #########
  # Hosts #
  #########
  Log -Message "Retrieve connected hosts and check if the tag $hosttag exists..." -Type Info -OutputMode File
  $vmhosts = $cluster | Get-VMHost -State Connected
  foreach ($vmhost in $vmhosts) {
    $hostTagAssigned = $vmhost | Get-TagAssignment -Category "Host Attributes"
    if ($hostTagAssigned) {
      foreach ($hosttagA in $hostTagAssigned) {
        if ($hosttagA.Tag.Name -eq $hosttag) {
          $windowsHosts += $vmhost
          $hostTagExists = $true
        }
      }
    }
  }

  #Create Windows host group if tag is found and group is not found
  if (!$hostGroupExists -and $hostTagExists -and $windowsHosts -ne $null) {
    Log -Message "Creating DRS Host group..." -Type Info -OutputMode File
    New-DrsClusterGroup -Name $hosttag-hostgrp -Cluster $cluster -VMHost $windowsHosts
    $drsHostGroup = Get-DrsClusterGroup -Cluster $cluster -Type VMHostGroup -Name ${hosttag}-hostgrp -ErrorAction SilentlyContinue
    if ($drsHostGroup) {
      $hostGroupExists = $true
    }
  }

  #Check if Hosts are a member of the DRS group
  if ($hostGroupExists -and $hostTagExists) {
    foreach ($windowsHost in $windowsHosts) {
      if (!$drsHostGroup.Member.Contains($windowsHost)) {
        #Host is NOT a member, adding
        Log -Message "Adding ESXi host $windowsHost to DRS Host Group..." -Type Info -OutputMode File
        $drsHostGroup | Set-DrsClusterGroup -Add -VMHost $windowshost
      }
    }
  }

  #######
  # VMs #
  #######
  
  Log -Message "Retrieve all vms and check if the tag $vmtag exists..." -Type Info -OutputMode File
  $vms = $cluster | Get-VM
  foreach ($vm in $vms) {
    $windowsTag = Get-Tag -name $vmtag -Category "VM Attributes"
    $vmOS = Out-String -InputObject $vm.Guest.OSFullName
    if ($vmOS.Contains("Windows")) {
      $vmTagAssigned = $vm | Get-TagAssignment -Category "VM Attributes" -Tag $vmtag
      if ($vmTagAssigned) {
        foreach ($vmtagA in $vmTagAssigned) {
          if ($vmtagA.Tag.Name -eq $vmtag) {
            $windowsVMs += $vm
            $vmTagExists = $true
          }
        }
      }
      else {
        Log -Message "Tagging VM $($vm.name) with tag $vmtag" -Type Info -OutputMode File
        New-TagAssignment -Entity $vm -Tag $windowsTag
        $windowsVMs += $vm
        $vmTagExists = $true
      }
    }
  }

  #Windows VMs found but no Windows hosts found. Should this be reported?
  if ($vmTagExists -and !$hostTagExists) {
    Log -Message "VMs with Windows tag exists, but there are no hosts with a Windows tag!" -Type Error -OutputMode Both
  }

  #Create Windows VM Group if tag is found and group is not found
  if (!$vmGroupExists -and $vmTagExists -and $windowsHosts -ne $null) {
    Log -Message "Creating DRS VM group..." -Type Info -OutputMode File
    New-DrsClusterGroup -Name $vmtag-vmgrp -Cluster $cluster -VM $windowsVMs
    $drsVMGroup = Get-DrsClusterGroup -Cluster $cluster -Type VMGroup -Name ${vmtag}-vmgrp -ErrorAction SilentlyContinue
    if ($drsVMGroup) {
      $vmGroupExists = $true
    }
  }

  #Check if VM are a member of the DRS group
  if ($vmGroupExists -and $vmTagExists) {
    foreach ($windowsVM in $windowsVMs) {
      if (!$drsVMGroup.Member.Contains($windowsVM)) {
        #VM is NOT a member, adding
        $drsVMGroup | Set-DrsClusterGroup -Add -VM $windowsVM
      }
    }
  }


  ############
  # DRS Rule #
  ############
  #Check DRS Rule
  if ($hostGroupExists -and $vmGroupExists) {
    $drsRules = Get-DrsVMHostRule -Cluster $cluster -Type ShouldRunOn -VMHostGroup $drsHostGroup -VMGroup $drsVMGroup
    if (!$drsRules) {
      #Rule doesn't exist
      Log -Message "Creating DRS rule..." -Type Info -OutputMode File
      New-DrsVMHostRule -Name $ruleName -Cluster $cluster -VMHostGroup $drsHostGroup -VMGroup $drsVMGroup -Type ShouldRunOn -Enabled:$ruleEnable
    }
  }
}

Disconnect-VIServer $vcenter -Confirm:$false
Log -Message "Disconnected from vCenter $vcenter..." -Type Info -OutputMode Both
Log -Message "Script ended..." -Type Info -OutputMode File
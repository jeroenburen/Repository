function Get-ScriptDirectory {
  $ScriptInvocation = (Get-Variable $MyInvocation -Scope 1).Value
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

function RotateLog {
  param(
    [parameter(mandatory=$true)][String]$Folder
  )
  $Target = Get-ChildItem $Folder -Filter "*.log"
  $Threshold = 30000 # Threshold in Bytes
  $DateTime = Get-Date -uformat "%Y-%m-%d-%H%M"
  $Target | ForEach-Object {
    if ($_.Length -ge $Threshold) { 
      Write-Host "File $($_.name) is bigger than $threshold B"
      $NewName = "$($_.BaseName)_${DateTime}.log_old"
      Rename-Item $_.fullname $NewName
      Write-Host "Done rotating file(s)" 
    }
    else {
      Write-Host "File $($_.name) is not bigger than $threshold B"
    }
    Write-Host " "
  }
}

function WriteToSQL {
param($Date,$VMName,$NumCPU)

# Data preparation for loading data into SQL table 
$InsertResults = @"
INSERT INTO [WindowsVMs].[dbo].[tbl_PRLG](Date,VMName,NumCPU)
VALUES ('$Date','$VMName','$NumCPU')
"@      

#call the invoke-sqlcmdlet to execute the query
Invoke-sqlcmd @params -Query $InsertResults
}

function Get-SQLData {
param($Date,$VMName,$NumCPU,$Customer)

# Data preparation for reading data from SQL table 
$GetResults = @"
DECLARE @startOfCurrentMonth DATETIME
SET @startOfCurrentMonth = DATEADD(month, DATEDIFF(month, 0, CURRENT_TIMESTAMP), 0)

SELECT     max(Date) as [Date], VMName, NumCPU, Customer
FROM        tbl_VMs
WHERE Date >= DATEADD(month, -1, @startOfCurrentMonth)
      AND Date < @startOfCurrentMonth
      AND Customer = 'PRLG'
GROUP BY VMName,NumCPU,Customer
ORDER BY VMName
"@      

#call the invoke-sqlcmdlet to execute the query
Invoke-sqlcmd @params -Query $GetResults
}

function GetVCFCredentials {
  
$vcfuser = Read-Host -Prompt "Please enter VCF User Name"
$vcfpass = Read-Host -Prompt "Please enter VCF Password"

Request-VCFToken -fqdn $sddcmanager -username $vcfuser -password $vcfpass

Get-VCFCredential -resourceType WSA
}


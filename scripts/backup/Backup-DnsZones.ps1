
# Set variables
$DnsServer = (Get-ADDomainController).HostName
$BackupFolder = ”D:\CI\Backup-DnsZones”

# Get all zones and create a backup
# This is done LOCALLY on the DNS server
Get-DnsServerZone -ComputerName $DnsServer | ?{$_.IsAutoCreated -eq $false} | %{Remove-Item -ErrorAction SilentlyContinue -LiteralPath "\backup\$($_.ZoneName).bak";Export-DnsServerZone -ComputerName $DnsServer -Name $_.ZoneName -FileName "\backup\$($_.ZoneName).bak"}

# Copy all backup files to this server
foreach ($Item in Get-ChildItem -Path \\$DnsServer\ADMIN$\System32\dns\backup) {
 Copy-Item -Path $Item.FullName -Destination $BackupFolder
}
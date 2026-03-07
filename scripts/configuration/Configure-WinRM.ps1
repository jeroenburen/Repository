"Create self-signed certificate..."
$IP = (Get-NetIPAddress -InterfaceAlias "Ethernet*" -AddressFamily IPv4).IPAddress
$CertificateThumbprint = (New-SelfSignedCertificate -DnsName $env:COMPUTERNAME,$IP -CertStoreLocation "Cert:\LocalMachine\My").Thumbprint

"Create HTTPS WinRM listener..."
$listener = @{
  ResourceURI = "winrm/config/Listener"
  SelectorSet = @{Address="*";Transport="HTTPS"}
  ValueSet = @{CertificateThumbprint=$CertificateThumbprint}
}

New-WSManInstance @listener

"Create firewall rule for allowing 5986 on all profiles..."
$rule = @{
  Name = "WINRM-HTTPS-In-TCP"
  DisplayName = "Windows Remote Management (HTTPS-In)"
  Description = "Inbound rule for Windows Remote Management via WS-Management. [TCP 5986]"
  Enabled = "true"
  Direction = "Inbound"
  Profile = "Any"
  Action = "Allow"
  Protocol = "TCP"
  LocalPort = "5986"
}

New-NetFirewallRule @rule


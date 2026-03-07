$mac = '70-85-c2-46-44-27'
$macbyte = $mac.split('-:') | %{ [byte]('0x' + $_) }
$packet = [byte[]](,0xFF * 6)
$packet += $macByte * 16
            
$UdpClient=New-Object System.Net.Sockets.UdpClient
$UdpClient.Connect(([System.Net.IPAddress]::Broadcast),4000)
[Void]$UdpClient.Send($Packet,$Packet.Length)
$UdpClient.Close()

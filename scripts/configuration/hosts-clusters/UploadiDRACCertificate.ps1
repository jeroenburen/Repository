$servers = Import-Csv -Path C:\Users\JeroenBuren\Desktop\iDRAC.csv
$credentials = Get-Credential -Message "Please enter valid iDRAC credentials"
$user = $credentials.UserName
$pass = $credentials.GetNetworkCredential().Password

foreach ($server in $servers) {
    $idrac = $server.iDRAC
    Invoke-Command -ScriptBlock {racadm.exe -r $idrac -u $credentials.UserName -p $credentials.GetNetworkCredential().Password sslkeyupload -t 1 -f C:\Users\JeroenBuren\Desktop\Certificaten\oob\wildcard.oob.ci.eurofiber.com.key}
    Invoke-Command -ScriptBlock {racadm.exe -r $idrac -u $credentials.UserName -p $credentials.GetNetworkCredential().Password sslcertupload -t 1 -f C:\Users\JeroenBuren\Desktop\Certificaten\oob\wildcard.oob.ci.eurofiber.com.cer}
}
# Define clear text string for username and password
[string]$Username = 'cursist3@M365x098712.onmicrosoft.com'
[string]$Password = ''

# Convert to SecureString
[securestring]$SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force

$Credentials = New-Object System.Management.Automation.PSCredential -ArgumentList $Username, $SecurePassword

Connect-MsolService -Credential $Credentials
# Variables
$vrops = "URL of your Aria Operations"
$username = "Your username"
$password = "Your password"

#############################
# Login to Aria Operations...
#############################

# Define API URL
$apiUrl = "https://$vrops/suite-api/api/auth/token/acquire"

# Define login credentials
$body = @{
    username = $username
    password = $password
    authSource = "WorkspaceONE" # For me this is WorkspaceONE
} | ConvertTo-Json

# Define HTTP headers
$headers = @{
    "Content-Type" = "application/json"
}

# Make the POST request to log in
$response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $body

# Extract the token from the response
$token = $response.token

# Display the token
Write-Output "Token: $token"

# Optionally store the token for future requests
$authHeaders = @{
    "Authorization" = "OpsToken $token"
}

#######################
# Generating a  Bill...
#######################
# Define API URL
$apiUrl = "https://{{vrops}}/suite-api/api/chargeback/bills"

# Define the JSON body as a PowerShell hashtable
$body = @{
    title            = "Test Bill Generation"
    description      = "Test Bill Generation"
    billingStartTime = 1665122400000
    billingEndTime   = 1666322044280
    resourceIds      = @("dfc2d007-be10-45c7-9fef-bd2f77b274ff")
    policyId         = "5e3d8255-1c5e-48dd-92c5-b7a687c3c898"
    timeZone         = "UTC"
} | ConvertTo-Json -Depth 3  # -Depth ensures nested objects/arrays are serialized properly

# Define HTTP headers
$headers = @{
    "Content-Type"  = "application/json"
    "Authorization" = "OpsToken $token"   # Replace with your actual token if required
}

# Make the POST request
$response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $body

# Output the API response
Write-Output $response

# Get the bill

# Define API URL
$apiUrl = "https://{{vrops}}/suite-api/api/chargeback/bills/{id}"

# Define HTTP headers
$headers = @{
    "Content-Type"  = "application/json"
    "Authorization" = "OpsToken $token"   # Replace with your actual token if required
}

# Make the POST request
$response = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers

# Output the API response
Write-Output $response

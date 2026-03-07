# Declare variables
$vrops    = "mgmt-vrops.domain.com"
$username = "user"
$password = ""
$source   = "WorkspaceONE"
$header   = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$header.Add("Accept","application/json")
$header.Add("Content-Type","application/json")

################################################################
# POST /api/auth/token/acquire Acquire an Authentication Token #
################################################################
$method   = "POST"
$URI      = "https://$vrops/suite-api/api/auth/token/acquire"

# Construct body
[hashtable]$body = @{}
$body.username = $username
$body.password = $password
$body.authSource = $source

$json = $body | ConvertTo-Json

# Login and retrieve the token
$token = Invoke-RestMethod -Uri $URI -Method $method -Headers $header -Body $json | Select-Object -expandproperty token

# Add the token to the header
$header.Add("Authorization","vRealizeOpsToken $token")

###########################################################################################
# POST /api/chargeback/bills Create and save the Bills based on the Bill Generate Request #
###########################################################################################
# {
#   "title" : "Test Bill Generation",
#   "description" : "Test Bill Generation",
#   "billingStartTime" : 1665122400000,
#   "billingEndTime" : 1666322044280,
#   "resourceIds" : [ "dfc2d007-be10-45c7-9fef-bd2f77b274ff" ],
#   "policyId" : "5e3d8255-1c5e-48dd-92c5-b7a687c3c898",
#   "timeZone" : "UTC"
# }
#
###########################################################################################
# curl -X GET "https://mgmt-vrops.ci.eurofiber.com/suite-api/api/policies?activesOnly=true&_no_links=true" -H "accept: application/json" -H "Authorization: OpsToken d98e30fc-0643-4e78-b8ae-8d4a81310a0f::e1532d97-b3ba-4ead-9411-1c9ffec66913"
# PRLG contract 409fd4f0-9588-4815-b01a-3df02bd75649

# $orgvdc = Invoke-RestMethod -Method Get -Uri "https://$vrops/suite-api/api/adapterkinds/vCloud/resourcekinds/ORG_VDC/resources?name=Hosting" -Headers $header
# $orgvdc.resourceList.identifier

# curl -X GET "https://mgmt-vrops.ci.eurofiber.com/suite-api/api/adapterkinds/vCloud/resourcekinds/ORG_VDC/resources?name=PRLG Hosting&page=0&pageSize=1000&_no_links=true" -H "accept: application/json" -H "Authorization: OpsToken d98e30fc-0643-4e78-b8ae-8d4a81310a0f::e1532d97-b3ba-4ead-9411-1c9ffec66913"
# "identifier": "c1345b35-c2ad-4c1e-af9b-0da891acb2f5"
# {
#   "generatedBills": [
#     {
#       "billId": "90c0923d-80f2-4a43-bdcb-1b02c187f4a4",
#       "resourceId": "c1345b35-c2ad-4c1e-af9b-0da891acb2f5"
#     }
#   ]
# }

#####################################################################################################################################
# POST /api/chargeback/bills/query Get metering Bills summary based on the Request                                                  #
# value": "RESOURCE_NAME, POLICY_NAME, TITLE, START_TIME, END_TIME, EXECUTION_TIME, TOTAL_PRICE, RESOURCE_TYPE, ASSIGNED_TO_TENANT" #
#####################################################################################################################################

$start = [System.DateTimeOffset]::new($(Get-Date).AddMonths(-1)).ToUnixTimeMilliseconds()
$end = [System.DateTimeOffset]::new($(Get-Date)).ToUnixTimeMilliseconds()

[hashtable]$body = @{}
$body.searchCriterias = @([ordered]@{
  key = "POLICY_NAME"; value = "PRLG contract"
})
$body.period = @{
    start = $start; end = $end
}

$json = $body | ConvertTo-Json

$URI = "https://$vrops/suite-api/api/chargeback/bills/query"
$bills = Invoke-RestMethod -Method POST -Uri $URI -Body $json -Headers $header

#############################################################################
# GET ​/api​/chargeback​/bills​/{id} Get bill for the specified bill identifier #
#############################################################################

$URI = "https://$vrops/suite-api/api/chargeback/bills/" + $bills.meteringBillSummaries.billId
$bill = Invoke-RestMethod -Method GET -Uri $URI -Headers $header


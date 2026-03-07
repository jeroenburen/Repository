# Requires: ImportExcel module
# Install it if needed: Install-Module -Name ImportExcel -Scope CurrentUser

$csvFolder = "C:\Users\jburen\50 Klant Documenten\S0VVCS0061i"
$outputExcel = "C:\Users\jburen\Downloads\S0VVCS0061i.xlsx"

# Get all CSV files in the folder
$csvFiles = Get-ChildItem -Path $csvFolder -Filter *.csv

foreach ($csv in $csvFiles) {
    $sheetName = ($csv.BaseName).Substring(11) # Excel sheet name limit
    $csvPath = $csv.FullName

    # Append each CSV to the Excel file as a new worksheet
    Import-Csv $csvPath -Delimiter ";"| Export-Excel -Path $outputExcel -WorksheetName $sheetName -AutoSize -Append
}

Write-Host "✅ All CSV files have been combined into $outputExcel"
$PowerCLImodules = @((Get-Module -ListAvailable | ? {$_.Name -like "VMware*"}).Name | Get-Unique)

foreach ($module in $PowerCLImodules){
    $latest = Get-InstalledModule -Name $module
    Get-InstalledModule -Name $module -AllVersions | ? {$_.Version -ne $latest.Version} | Uninstall-Module -Force -Verbose
    }

Install-Module VMware.PowerCLI
Function Get-FoundationCoreAndTiBUsage {
<#
    .DESCRIPTION Retrieves CPU Core/Storage usage analysis for vSphere Foundation (VVF) and VMware Cloud Foundation (VCF)
    .NOTES  Author:  William Lam, Broadcom
    .NOTES  Last Updated: 02/12/2024
    .PARAMETER ClusterName
        Name of a specific vSphere Cluster
    .PARAMETER CSV
        Output to CSV file
    .PARAMETER Filename
        Specific filename to save CSV file (default: <vcenter name>.csv and <vcenter name>-vsan.csv)
    .PARAMETER CollectLicenseKey
        Collect ESXi and/or vSAN License Key for each host
    .EXAMPLE
        Get-FoundationCoreAndTiBUsage -DeploymentType VCF
    .EXAMPLE
        Get-FoundationCoreAndTiBUsage -DeploymentType VVF
    .EXAMPLE
        Get-FoundationCoreAndTiBUsage -ClusterName "ML Cluster" -DeploymentType VCF
    .EXAMPLE
        Get-FoundationCoreAndTiBUsage -ClusterName "ML Cluster" -DeploymentType VCF -CSV
    .EXAMPLE
        Get-FoundationCoreAndTiBUsage -ClusterName "ML Cluster" -DeploymentType VCF -CSV -Filename "ML Cluster-Cluster.csv"
    .EXAMPLE
        Get-FoundationCoreAndTiBUsage -ClusterName "ML Cluster" -DeploymentType VCF -CollectLicenseKey
#>
    param(
        [Parameter(Mandatory=$false)][string]$ClusterName,
        [Parameter(Mandatory=$false)][string]$Filename,
        [Parameter(Mandatory=$true)][ValidateSet("VCF","VVF")][String]$DeploymentType,
        [Switch]$Csv,
        [Switch]$CollectLicenseKey,
        [Switch]$DemoMode
    )

    # Helper Function to build out Computer usage object
    Function BuildFoundationUsage {
        param(
            [Parameter(Mandatory=$false)]$cluster,
            [Parameter(Mandatory=$true)]$vmhost,
            [Parameter(Mandatory=$false)][Boolean]$CollectLicenseKey,
            [Parameter(Mandatory=$false)][Boolean]$DemoMode
        )

        if($cluster -eq $null) {
            $cluster = (Get-Cluster -VMHost (Get-VMHost -Name $vmhost.name)).ExtensionData

            # Determine if ESXi is in cluster
            if($cluster -ne $null) {
                $clusterName = $cluster.name
            }
        } else {
            $clusterName = $cluster.name
        }

        $vmhostName = $vmhost.name

        $sockets = $vmhost.Hardware.CpuInfo.NumCpuPackages
        $coresPerSocket = ($vmhost.Hardware.CpuInfo.NumCpuCores / $sockets)

        # Check if hosts is running vSAN
        if($vmhost.Runtime.VsanRuntimeInfo.MembershipList -ne $null) {
            $isVSANHost = $true
            $vsanClusters[$clusterName] = 1
        } else {
            $isVSANHost = $false
            $vsanLicenseCount = 0
        }

        # vSphere & vSAN
        if($coresPerSocket -le 16) {
            $vsphereLicenseCount = $sockets * 16
            if($isVSANHost) {
                $vsanLicenseCount = $sockets * 16
            }
        } else {
            $vsphereLicenseCount =  $sockets * $coresPerSocket
            if($isVSANHost) {
                $vsanLicenseCount = $sockets * $coresPerSocket
            }
        }

        # Collect vSphere and vSAN License Key
        $vsphereLicenseKey = "N/A"
        $vsanLicenseKey = "N/A"

        if($CollectLicenseKey) {
            $hostLicenses = $licenseAssignementManager.QueryAssignedLicenses($vmhost.MoRef.Value)
            foreach ($hostLicense in $hostLicenses) {
                if($hostLicense.AssignedLicense.EditionKey -match "esx") {
                    $vsphereLicenseKey = $hostLicense.AssignedLicense.LicenseKey
                    break
                }
            }

            if($isVSANHost) {
                $clusterLicenses = $licenseAssignementManager.QueryAssignedLicenses($cluster.MoRef.Value)

                foreach ($clusterLicense in $clusterLicenses) {
                    if($clusterLicense.AssignedLicense.EditionKey -match "vsan") {
                        $vsanLicenseKey = $clusterLicense.AssignedLicense.LicenseKey
                        break
                    }
                }
            }

            # demo purpose without print license keys
            if($DemoMode) {
                if($vsphereLicenseKey -notmatch "00000" -and $vsphereLicenseKey -notmatch "N/A") {
                    $vsphereLicenseKey = "DEMO!-DEMO!-DEMO!-DEMO!-DEMO!"
                }

                if($vsanLicenseKey -notmatch "0000" -and $vsanLicenseKey -notmatch "N/A") {
                    $vsanLicenseKey = "DEMO!-DEMO!-DEMO!-DEMO!-DEMO!"
                }
            }
        }

        $tmp = [pscustomobject] @{
            CLUSTER = $clusterName;
            VMHOST = $vmhostName;
            NUM_CPU_SOCKETS = $sockets;
            NUM_CPU_CORES_PER_SOCKET = $coresPerSocket;
            FOUNDATION_LICENSE_CORE_COUNT = $vsphereLicenseCount;
            VSAN_CORE_COUNT = $coresPerSocket * $sockets;
            VSAN_LICENSE_CORE_COUNT = $vsanLicenseCount;
        }

        if($CollectLicenseKey) {
            $tmp | Add-Member -NotePropertyName VSPHERE_LICENSE_KEY -NotePropertyValue $vsphereLicenseKey
            $tmp | Add-Member -NotePropertyName VSAN_LICENSE_KEY -NotePropertyValue $vsanLicenseKey
        }

        return $tmp
    }

    # Helper Function to build out vSAN usage object
    Function BuildvSANUsage {
        param(
            [Parameter(Mandatory=$false)][string]$ClusterName,
            [Parameter(Mandatory=$false)]$TmpResults
        )

        $vsanUsageResult = Get-VsanSpaceUsage -Cluster $ClusterName

        $vsanLicenseTibCount = $vsanUsageResult.CapacityGB / 1024 # Convert GiB->TiB
        $vsanTotalHostCount = [int](($TmpResults | where {$_.CLUSTER -eq $clusterName}).VMHOST).count
        $vsanTotalCPUCount = [int](($TmpResults | where {$_.CLUSTER -eq $clusterName}).NUM_CPU_SOCKETS | Measure-Object -Sum).Sum
        $vsanTotalCPUCores = [int](($TmpResults | where {$_.CLUSTER -eq $clusterName}).VSAN_CORE_COUNT | Measure-Object -Sum).Sum
        $entitledFoundationLicenseCore = [int](($TmpResults | where {$_.CLUSTER -eq $clusterName}).FOUNDATION_LICENSE_CORE_COUNT | Measure-Object -Sum).Sum

        # Remove minimum purchase of 8TiB per CPU Socket
        $minVsanLicenseTibCount = 0

        $enableVVFVsanTiBCalculation = $true

        if($DeploymentType -eq "VCF") {
            $entitledVsanTib = ($entitledFoundationLicenseCore * 1)
        } elseif($DeploymentType -eq "VVF" -and $enableVVFVsanTiBCalculation) {
            $entitledVsanTib = ($entitledFoundationLicenseCore * 0.09765625)
        } else {
            $entitledVsanTib = 0
        }

        if($DeploymentType -eq "VVF") {
            # If 100GiB entitlement is sufficient and you do NOT need additional vSAN storage, then required vSAN TiB = 0
            if($entitledVsanTib -ge $vsanLicenseTibCount) {
                $totalRequiredVsanTiBLicenseCount = 0
            } else {
                # Ensure the minimum 8TiB/CPU > Entitled
                $totalRequiredVsanTiBLicenseCount = (($minVsanLicenseTibCount,$entitledVsanTib)|Measure-Object -Maximum).Maximum
                # Then compare that value to the needed vSAN storage to determine the required vSAN TiB add-on purchase
                $totalRequiredVsanTiBLicenseCount = (($totalRequiredVsanTiBLicenseCount,$vsanLicenseTibCount)|Measure-Object -Maximum).Maximum
            }
        } else {
            # Ensure the minimum 8TiB/CPU > Required
            $totalRequiredVsanTiBLicenseCount = (($minVsanLicenseTibCount,$vsanLicenseTibCount)|Measure-Object -Maximum).Maximum
            $totalRequiredVsanTiBLicenseCount = ($totalRequiredVsanTiBLicenseCount - $entitledVsanTib)
        }

        $tmpVsanResult = [pscustomobject] @{
            CLUSTER = $clusterName;
            NUM_HOSTS = $vsanTotalHostCount;
            NUM_CPU_SOCKETS = $vsanTotalCPUCount
            NUM_CPU_CORES = $vsanTotalCPUCores;
            FOUNDATION_LICENSE_CORE_COUNT = $entitledFoundationLicenseCore;
            ENTITLED_VSAN_LICENSE_TIB_COUNT = $entitledVsanTib;
            REQUIRED_VSAN_TIB_CAPACITY = $vsanLicenseTibCount;
            VSAN_LICENSE_TIB_COUNT = [math]::Ceiling($totalRequiredVsanTiBLicenseCount);
        }

        if($DeploymentType -eq "VVF" -and $enableVVFVsanTiBCalculation -eq $false) {
            $tmpVsanResult = $tmpVsanResult | Select-Object -ExcludeProperty ENTITLED_VSAN_LICENSE_TIB_COUNT
        }

        return $tmpVsanResult
    }

    $results = @()
    $vsanResults = @()
    $tmpResults = @()
    $vsanClusters = @{}

    if($CollectLicenseKey) {
        $licenseManager = Get-View $global:DefaultVIServer.ExtensionData.Content.LicenseManager
        $licenseAssignementManager = Get-View $licenseManager.licenseAssignmentManager
    }

    if($ClusterName) {
        try {
            Get-Cluster -Name $ClusterName -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Host "`nCluster with name '$ClusterName' was not found`n" -ForegroundColor Red
            break
        }

        Write-Host "`nQuerying vSphere Cluster: $ClusterName`n"  -ForegroundColor cyan

        $clusters = Get-View -ViewType ClusterComputeResource -Property Name,Host,ConfigurationEx -Filter @{"name"=$ClusterName}
        foreach ($cluster in $clusters) {
            try {
                $vmhosts = Get-View $cluster.host -Property Name,Hardware.systemInfo,Hardware.CpuInfo,Runtime
            } catch {
                continue
            }
            foreach ($vmhost in $vmhosts) {
                # Ingore HCX IX & vSAN Witness Node
                if($vmhost.Hardware.systemInfo.Model -ne "VMware Mobility Platform" -and (Get-AdvancedSetting -Entity $vmhost.name Misc.vsanWitnessVirtualAppliance).Value -eq 0) {
                    $result = BuildFoundationUsage -cluster $cluster -vmhost $vmhost -CollectLicenseKey $CollectLicenseKey -DemoMode $DemoMode

                    $tmpResults += $result

                    $result = $result | Select-Object -ExcludeProperty VSAN_CORE_COUNT,VSAN_LICENSE_CORE_COUNT
                    $results += $result
                }
            }

            # vSAN Storage Usage
            if($cluster.ConfigurationEx.VsanConfigInfo.Enabled) {
                $tmpVsanResult = BuildvSANUsage -ClusterName $ClusterName -TmpResults $tmpResults

                $vsanResults += $tmpVsanResult
            }
        }
    } else {
        Write-Host "`nQuerying all ESXi hosts, this may take several minutes..." -ForegroundColor cyan

        $vmhosts = Get-View -ViewType HostSystem -Property Name,Hardware.systemInfo,Hardware.CpuInfo,Runtime
        $cluster = $null

        foreach ($vmhost in $vmhosts) {
            # Ingore HCX IX & vSAN Witness Node
            if($vmhost.Hardware.systemInfo.Model -ne "VMware Mobility Platform" -and (Get-AdvancedSetting -Entity $vmhost.name Misc.vsanWitnessVirtualAppliance).Value -eq 0) {
                $result = BuildFoundationUsage -cluster $cluster -vmhost $vmhost -CollectLicenseKey $CollectLicenseKey -DemoMode $DemoMode

                $tmpResults += $result
                $result = $result | Select-Object -ExcludeProperty VSAN_CORE_COUNT,VSAN_LICENSE_CORE_COUNT

                $results += $result
            }
        }

        foreach ($key in $vsanClusters.keys) {
            $tmpVsanResult = BuildvSANUsage -ClusterName $key -TmpResults $tmpResults
            $vsanResults += $tmpVsanResult

        }
    }

    $deploymentTypeString = @{
        "VCF" = "VMware Cloud Foundation (VCF) Instance"
        "VVF" = "VMware vSphere Foundation (VVF)"
    }

    Write-Host -ForegroundColor Yellow "`nSizing Results for $($deploymentTypeString[$DeploymentType]):"

    if($CSV) {
        If(-Not $Filename) {
            $Filename = "$($global:DefaultVIServer.Name).csv"
        }

        Write-Host "`nSaving output as CSV file to $Filename`n"
        $results | Sort-Object -Property CLUSTER | ConvertTo-Csv -NoTypeInformation | Out-File -FilePath $Filename

        if($vsanResults.count -gt 0) {
            $vsanFileName = $Filename.replace(".csv","-vsan.csv")
            Write-Host "Saving output as CSV file to $vsanFileName`n"
            $vsanResults | Sort-Object -Property CLUSTER | ConvertTo-Csv -NoTypeInformation | Out-File -FilePath $vsanFileName
        }
    } else {
        Write-Host "`nCompute Usage Information" -ForegroundColor Magenta
        if (($results | measure).Count -eq 0)  {
            Write-Host "`nESXi Hosts were not found with searching criteria`n" -ForegroundColor Red
        } else {
            $results | Sort-Object -Property CLUSTER | ft
        }

        if($vsanResults.count -gt 0) {
            Write-Host "vSAN Usage Information" -ForegroundColor Magenta
            $vsanResults | Sort-Object -Property CLUSTER | ft
        }
    }

    Write-Host "`Total Required $DeploymentType Compute Licenses: " -ForegroundColor cyan -NoNewline
    ($results.FOUNDATION_LICENSE_CORE_COUNT|Measure-Object -Sum).Sum

    Write-Host "Total Required vSAN Add-on Licenses: " -ForegroundColor cyan -NoNewline
    if($vsanResults.count -gt 0) {
        $aggTotalVcfRequiredVsanLicenseTib = ($vsanResults.VSAN_LICENSE_TIB_COUNT|Measure-Object -Sum).Sum
        $aggTotalVcfRequiredVsanLicenseTib
    }

    Write-Host "`n"
}
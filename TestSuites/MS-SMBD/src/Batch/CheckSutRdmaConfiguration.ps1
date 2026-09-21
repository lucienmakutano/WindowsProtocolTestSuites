# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [switch]$AllowRdmaOnNonRnicAddress
)

$ErrorActionPreference = "Stop"
$failureCount = 0
$warningCount = 0

function Write-CheckResult {
    param(
        [bool]$Passed,
        [string]$Message
    )

    if ($Passed) {
        Write-Host "[PASS] $Message" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Message" -ForegroundColor Red
        $script:failureCount++
    }
}

function Write-CheckWarning {
    param([string]$Message)

    Write-Host "[WARN] $Message" -ForegroundColor Yellow
    $script:warningCount++
}

function Find-Configuration {
    $candidates = @(
        $ConfigPath,
        (Join-Path $PSScriptRoot "../Bin/MS-SMBD_ServerTestSuite.deployment.ptfconfig"),
        (Join-Path $PSScriptRoot "../TestSuite/MS-SMBD_ServerTestSuite.deployment.ptfconfig"),
        (Join-Path $PSScriptRoot "../MS-SMBD_ServerTestSuite.deployment.ptfconfig")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Deployment configuration was not found. Pass -ConfigPath explicitly."
}

function Get-ConfigurationProperties {
    param([string]$Path)

    [xml]$configuration = Get-Content -LiteralPath $Path
    $properties = @{}
    foreach ($property in $configuration.SelectNodes("//*[local-name()='Property']")) {
        $properties[$property.name] = $property.value
    }
    return $properties
}

function Get-AdapterForAddress {
    param([string]$Address)

    $ipAddress = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Address -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $ipAddress) {
        return $null
    }

    return Get-NetAdapter -InterfaceIndex $ipAddress.InterfaceIndex -ErrorAction SilentlyContinue
}

function Test-ConfiguredInterface {
    param(
        [string]$Label,
        [string]$Address,
        [bool]$ExpectRdma
    )

    $adapter = Get-AdapterForAddress -Address $Address
    Write-CheckResult ($null -ne $adapter) "$Label address $Address is assigned to a network adapter"
    if ($null -eq $adapter) {
        return
    }

    Write-CheckResult ($adapter.Status -eq "Up") "$Label adapter '$($adapter.Name)' is up ($($adapter.LinkSpeed))"

    $rdma = Get-NetAdapterRdma -Name $adapter.Name -ErrorAction SilentlyContinue
    $rdmaOperational = $null -ne $rdma -and $rdma.Enabled -and $rdma.OperationalState
    if ($ExpectRdma) {
        Write-CheckResult $rdmaOperational "$Label adapter '$($adapter.Name)' has operational RDMA"
    } elseif ($rdmaOperational -and $AllowRdmaOnNonRnicAddress) {
        Write-CheckWarning "$Label address $Address is configured as non-RNIC but '$($adapter.Name)' is RDMA-capable"
    } else {
        Write-CheckResult (-not $rdmaOperational) "$Label adapter '$($adapter.Name)' is non-RDMA as required by the config property"
    }

    foreach ($componentId in @("ms_tcpip", "ms_server")) {
        $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID $componentId -ErrorAction SilentlyContinue
        Write-CheckResult ($null -ne $binding -and $binding.Enabled) "$componentId binding is enabled on '$($adapter.Name)'"
    }

    $smbInterface = Get-SmbServerNetworkInterface -ErrorAction SilentlyContinue |
        Where-Object { $_.IpAddress -eq $Address } |
        Select-Object -First 1
    Write-CheckResult ($null -ne $smbInterface) "SMB server advertises $Address"
    if ($ExpectRdma -and $null -ne $smbInterface) {
        Write-CheckResult $smbInterface.RdmaCapable "SMB reports $Address as RDMA-capable"
    }
}

function Test-PairedRoute {
    param(
        [string]$LocalAddress,
        [string]$PeerAddress,
        [string]$Label
    )

    $adapter = Get-AdapterForAddress -Address $LocalAddress
    if ($null -eq $adapter) {
        return
    }

    try {
        $route = Test-NetConnection -ComputerName $PeerAddress -DiagnoseRouting -InformationLevel Detailed
        $selectedSourceAddress = $route.SelectedSourceAddress
        if ($null -ne $selectedSourceAddress.IPAddress) {
            $sourceAddress = [string]$selectedSourceAddress.IPAddress
        } else {
            $sourceAddress = [string]$selectedSourceAddress
        }
        $outgoingInterfaceIndex = $route.OutgoingInterfaceIndex
        if ($null -eq $outgoingInterfaceIndex -and $null -ne $route.SelectedNetRoute) {
            $outgoingInterfaceIndex = $route.SelectedNetRoute.InterfaceIndex
        }
        $interfaceMatches = $outgoingInterfaceIndex -eq $adapter.ifIndex
        Write-CheckResult ($interfaceMatches -and $sourceAddress -eq $LocalAddress) `
            "$Label peer $PeerAddress routes from $LocalAddress through '$($adapter.Name)' (selected source: $sourceAddress, interface: $outgoingInterfaceIndex)"
    } catch {
        Write-CheckResult $false "$Label route to $PeerAddress could not be diagnosed: $($_.Exception.Message)"
    }
}

$resolvedConfigPath = Find-Configuration
$config = Get-ConfigurationProperties -Path $resolvedConfigPath

Write-Host "MS-SMBD SUT RDMA configuration check"
Write-Host "Config: $resolvedConfigPath"
Write-Host "Computer: $env:COMPUTERNAME"

$requiredProperties = @("ServerRNicIp", "ServerNonRNicIp", "ClientRNicIp", "ClientNonRNicIp")
foreach ($propertyName in $requiredProperties) {
    Write-CheckResult ($config.ContainsKey($propertyName) -and -not [string]::IsNullOrWhiteSpace($config[$propertyName])) `
        "Configuration contains $propertyName"
}

$smbConfiguration = Get-SmbServerConfiguration
Write-CheckResult $smbConfiguration.EnableMultiChannel "SMB Multichannel is enabled"

$smbListener = Get-NetTCPConnection -State Listen -LocalPort 445 -ErrorAction SilentlyContinue
Write-CheckResult ($null -ne $smbListener) "SMB is listening on TCP port 445"

Test-ConfiguredInterface -Label "SUT RNIC" -Address $config.ServerRNicIp -ExpectRdma $true
Test-ConfiguredInterface -Label "SUT non-RNIC" -Address $config.ServerNonRNicIp -ExpectRdma $false
Test-PairedRoute -LocalAddress $config.ServerRNicIp -PeerAddress $config.ClientRNicIp -Label "RNIC"
Test-PairedRoute -LocalAddress $config.ServerNonRNicIp -PeerAddress $config.ClientNonRNicIp -Label "Non-RNIC"

Write-Host ""
Write-Host "Network adapters:"
Get-NetAdapter | Sort-Object ifIndex |
    Format-Table Name, InterfaceDescription, Status, LinkSpeed, ifIndex -AutoSize

Write-Host "RDMA adapters:"
Get-NetAdapterRdma | Format-Table Name, Enabled, OperationalState, PFC, ETS -AutoSize

Write-Host "Summary: $failureCount failure(s), $warningCount warning(s)."
if ($failureCount -gt 0) {
    exit 1
}
exit 0
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [Parameter(Mandatory)]
    [string[]]$Binaries,     # An array containing name of the test binaries.
    [string]$Filter = "",    # Expression used to filter test cases.For example, "TestCategory=BVT&TestCategory=SMB311" will filter out test cases which have test category BVT and SMB311. 
    [switch]$DryRun = $false, # If set, just list all filtered test cases instead of running tests actually.
    [string]$BinPath = ""
)

$invocationPath = $PSScriptRoot

$rootPath = Split-Path $invocationPath -Parent

if ([String]::IsNullOrEmpty($BinPath)) {
    $binCandidates = @(
        (Join-Path $rootPath "Bin"),
        (Join-Path $rootPath "../../../drop/TestSuites/MS-SMBD-user/Bin"),
        (Join-Path $rootPath "../../../drop/TestSuites/MS-SMBD/Bin")
    )
    $BinPath = $binCandidates | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ "MS-SMBD_ServerTestSuite.dll") -PathType Leaf
    } | Select-Object -First 1
}

if ([String]::IsNullOrEmpty($BinPath)) {
    Write-Error "No MS-SMBD build output was found. Run build.sh or specify -BinPath."
    exit 1
}

$binPath = (Resolve-Path -LiteralPath $BinPath).Path

$testResultPath = Join-Path (Split-Path $binPath -Parent) "TestResults"

$testBinariesWithPath = $Binaries | ForEach-Object -Process { Join-Path $binPath $_ }

foreach ($testBinary in $testBinariesWithPath) {
    if (-not (Test-Path -LiteralPath $testBinary -PathType Leaf)) {
        Write-Error "Test binary not found: $testBinary. Build and deploy the test suite before running this script."
        exit 1
    }
}

$localDotnet = Join-Path $HOME ".dotnet/dotnet"
if (Test-Path -LiteralPath $localDotnet -PathType Leaf) {
    $dotnetCommand = $localDotnet
} else {
    $dotnetCommand = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
}

if ([String]::IsNullOrEmpty($dotnetCommand)) {
    Write-Error "dotnet was not found in PATH. Install the .NET SDK before running this script."
    exit 1
}

if ([String]::IsNullOrEmpty($env:DOTNET_ROLL_FORWARD)) {
    $env:DOTNET_ROLL_FORWARD = "Major"
}

$dotnetArguments = @("test") + $testBinariesWithPath

if (-not [String]::IsNullOrEmpty($Filter)) {
    $dotnetArguments += @("--filter", $Filter)
}

if ($DryRun) {
    $dotnetArguments += "--list-tests"
} else {
    New-Item -ItemType Directory -Path $testResultPath -Force | Out-Null
    $dotnetArguments += @("--logger", "trx", "--ResultsDirectory", $testResultPath)
}

if (-not $DryRun -and $IsLinux) {
    $memlockLine = Get-Content "/proc/$PID/limits" | Where-Object { $_ -match "^Max locked memory" }
    $memlockLimit = if ($memlockLine -match "^Max locked memory\s+(\S+)") { $Matches[1] } else { "unknown" }

    if ($memlockLimit -ne "unlimited" -and [long]$memlockLimit -lt 67108864) {
        Write-Host "The RDMA tests require at least 64 MiB of locked memory; this process is limited to $memlockLimit bytes."
        Write-Host "Prompting for sudo so the memlock limit can be raised for this test process..."

        $userId = (& id -u).Trim()
        $groupId = (& id -g).Trim()

        & sudo prlimit --memlock=unlimited:unlimited -- setpriv "--reuid=$userId" "--regid=$groupId" --init-groups env "HOME=$HOME" "PATH=$env:PATH" $dotnetCommand @dotnetArguments
        exit $LASTEXITCODE
    }
}

& $dotnetCommand @dotnetArguments
exit $LASTEXITCODE

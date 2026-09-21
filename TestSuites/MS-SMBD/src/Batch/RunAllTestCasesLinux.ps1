# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [switch]$DryRun = $false, # If set, just list all test cases instead of running tests actually.
    [string]$BinPath = ""
)

$invocationPath = $PSScriptRoot

Write-Host "Running all test cases in MS-SMBD test suite..."
Write-Host "Path: $invocationPath"

$script = Join-Path $invocationPath "RunTestCasesByFilterLinux.ps1"

& $script -DryRun:$DryRun.IsPresent -BinPath $BinPath
exit $LASTEXITCODE
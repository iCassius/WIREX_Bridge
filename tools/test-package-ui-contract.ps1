[CmdletBinding()]
param([string]$PackageRoot)
$ErrorActionPreference='Stop'
$repo=if([string]::IsNullOrWhiteSpace($PackageRoot)){[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))}else{[System.IO.Path]::GetFullPath($PackageRoot)}
Import-Module (Join-Path $PSScriptRoot 'package-ui-contract.psm1') -Force -ErrorAction Stop
$result=Test-WirexR123UiPackageContract -PackageRoot $repo
Write-Output ('PASS: R123 package UI source contract ({0} structural assertions; no build or package copy)' -f $result.assertions)
#requires -Version 7.2
param(
    [Parameter(Mandatory)] [string] $StateDirectory,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{32}$')] [string] $Token
)
$ErrorActionPreference = 'Stop'
try {
    if (-not $IsWindows) { throw 'AwakeMate requires Windows.' }
    Import-Module (Join-Path $PSScriptRoot 'AwakeMate.psm1') -Force
    Invoke-AwakeMateWatchdog -StateDirectory $StateDirectory -Token $Token
}
catch {
    [Console]::Error.WriteLine("AwakeMate watchdog: $_")
    exit 1
}

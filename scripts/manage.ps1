#requires -Version 7.2
param(
    [Parameter(Mandatory)] [ValidateSet('Status', 'Restore')] [string] $Action
)
$ErrorActionPreference = 'Stop'
try {
    if (-not $IsWindows) { throw 'AwakeMate requires Windows.' }
    Import-Module (Join-Path $PSScriptRoot 'AwakeMate.psm1') -Force
    if ($Action -eq 'Status') {
        Invoke-AwakeMate -Action Status | ConvertTo-Json -Depth 10
    }
    else {
        Invoke-AwakeMate -Action Restore
        'Recovery complete. Any manually selected power plan was preserved.'
    }
}
catch {
    [Console]::Error.WriteLine("AwakeMate: $_")
    exit 1
}

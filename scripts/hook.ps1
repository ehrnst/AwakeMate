#requires -Version 7.2
param(
    [Parameter(Mandatory)] [ValidateSet('Acquire', 'Release')] [string] $Event
)
$ErrorActionPreference = 'Stop'
try {
    if (-not $IsWindows) { throw 'AwakeMate must run on the Windows host, not WSL or a remote Linux runtime.' }
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
    if ($payload -isnot [hashtable]) { throw 'Expected a JSON hook payload on stdin.' }
    # A subagent's stop must not release its parent's lease.
    if ($payload.agentId -or $payload.agent_id) {
        '{}'
        exit 0
    }
    $sessionId = if ($payload.sessionId) { $payload.sessionId } else { $payload.session_id }
    if ($sessionId -isnot [string] -or [string]::IsNullOrWhiteSpace($sessionId)) {
        throw 'The hook payload must contain sessionId or session_id.'
    }
    Import-Module (Join-Path $PSScriptRoot 'AwakeMate.psm1') -Force
    Invoke-AwakeMate -Action $Event -SessionId $sessionId
    '{}'
}
catch {
    [Console]::Error.WriteLine("AwakeMate: $_")
    exit 1
}

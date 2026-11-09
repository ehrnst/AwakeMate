#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AiStateDirectory {
    if (-not $env:LOCALAPPDATA) {
        throw 'LOCALAPPDATA is not defined. AwakeMate requires a local Windows user profile.'
    }
    Join-Path $env:LOCALAPPDATA 'copilot-AwakeMate'
}

function Invoke-AiPowerCfg {
    param([string[]] $Arguments)
    $output = & "$env:SystemRoot\System32\powercfg.exe" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg $($Arguments -join ' ') failed ($LASTEXITCODE): $($output -join ' ')"
    }
    $output -join "`n"
}

function Get-AiActiveScheme {
    $output = Invoke-AiPowerCfg -Arguments @('/getactivescheme')
    $match = [regex]::Match($output, '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if (-not $match.Success) {
        throw "Cannot read the active power scheme: $output"
    }
    $match.Value.ToLowerInvariant()
}

function Get-AiProcessIdentity {
    param([int] $ProcessId)
    $process = Get-Process -Id $ProcessId -ErrorAction Ignore
    if (-not $process) { return $null }
    @{ pid = $ProcessId; started = $process.StartTime.ToUniversalTime().Ticks.ToString() }
}

function Test-AiProcessIdentity {
    param([hashtable] $Identity)
    if (-not $Identity) { return $false }
    $current = Get-AiProcessIdentity $Identity.pid
    $null -ne $current -and $current.started -eq $Identity.started
}

function Get-AiOwnerIdentity {
    $processId = $PID
    for ($depth = 0; $depth -lt 32; $depth++) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId = $processId"
        if (-not $process) { break }
        # Hook shells are short-lived. Track the nearest agent/runtime ancestor instead.
        if ($processId -ne $PID -and $process.Name -match '^(copilot|node|Code|Code - Insiders)(\.exe)?$') {
            $identity = Get-AiProcessIdentity $processId
            if (-not $identity) { throw 'The agent process exited while acquiring its power lease.' }
            return $identity
        }
        $processId = [int] $process.ParentProcessId
        if ($processId -le 0) { break }
    }
    throw 'Cannot identify a Copilot/node/VS Code ancestor. Run this command through a local Copilot hook.'
}

function Enter-AiLock {
    param([string] $Directory)
    $null = [IO.Directory]::CreateDirectory($Directory)
    $path = Join-Path $Directory 'state.lock'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if ($timer.Elapsed.TotalSeconds -ge 10) {
                throw "Timed out waiting for the AwakeMate recovery-state lock: $path"
            }
            Start-Sleep -Milliseconds 100
        }
    } while ($true)
}

function Read-AiState {
    param([string] $Directory)
    $path = Join-Path $Directory 'state.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    $state = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
    $originalGuid = [guid]::Empty
    $temporaryGuid = [guid]::Empty
    if ($state.version -ne 1 -or $state.phase -notin @('preparing', 'active', 'restoring') -or
        -not [guid]::TryParseExact($state.original, 'D', [ref] $originalGuid) -or
        -not [guid]::TryParseExact($state.temporary, 'D', [ref] $temporaryGuid) -or $originalGuid -eq $temporaryGuid -or
        $state.leases -isnot [array]) {
        throw "Invalid AwakeMate recovery state at $path. Do not delete it before recovering the original plan."
    }
    $state
}

function Write-AiState {
    param([string] $Directory, [hashtable] $State)
    $path = Join-Path $Directory 'state.json'
    $temporary = Join-Path $Directory 'state.next'
    $json = ConvertTo-Json -InputObject $State -Depth 10
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    if ([IO.File]::Exists($path)) {
        [IO.File]::Replace($temporary, $path, [System.Management.Automation.Language.NullString]::Value)
    }
    else { [IO.File]::Move($temporary, $path) }
}

function Restore-AiScheme {
    param([string] $Directory, [hashtable] $State)
    $State.phase = 'restoring'
    Write-AiState $Directory $State
    if ((Get-AiActiveScheme) -eq $State.temporary) {
        $null = Invoke-AiPowerCfg -Arguments @('/setactive', $State.original)
        if ((Get-AiActiveScheme) -ne $State.original) {
            throw 'Windows did not restore the original power plan. Recovery state has been retained.'
        }
    }
    # A user-selected plan takes precedence; only remove our own, now-inactive plan.
    $schemes = Invoke-AiPowerCfg -Arguments @('/list')
    if ($schemes -match [regex]::Escape($State.temporary)) {
        $null = Invoke-AiPowerCfg -Arguments @('/delete', $State.temporary)
    }
    [IO.File]::Delete((Join-Path $Directory 'state.json'))
}

function Start-AiWatchdog {
    param([string] $Directory, [string] $Token)
    $ready = Join-Path $Directory "ready-$Token"
    $executable = Join-Path $PSHOME 'pwsh.exe'
    $script = Join-Path $PSScriptRoot 'watchdog.ps1'
    # Start-Process requires quoting embedded spaces in its Windows argument string.
    $arguments = "-NoLogo -NoProfile -NonInteractive -STA -File `"$script`" -StateDirectory `"$Directory`" -Token $Token"
    $process = Start-Process -FilePath $executable -ArgumentList $arguments -WindowStyle Hidden -PassThru
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists($ready)) {
            if ($process.HasExited) { throw 'The recovery watchdog exited before becoming ready.' }
            if ($timer.Elapsed.TotalSeconds -gt 5) { throw 'The recovery watchdog did not become ready within five seconds.' }
            Start-Sleep -Milliseconds 50
        }
        $identity = Get-AiProcessIdentity $process.Id
        if (-not $identity) { throw 'The recovery watchdog exited during startup.' }
        return $identity
    }
    finally { [IO.File]::Delete($ready) }
}

function Invoke-AwakeMate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Acquire', 'Release', 'Restore', 'Status', 'Pause')] [string] $Action,
        [string] $SessionId,
        [string] $ExpectedToken,
        [string] $StateDirectory = (Get-AiStateDirectory)
    )
    if ($Action -in @('Acquire', 'Release') -and [string]::IsNullOrWhiteSpace($SessionId)) {
        throw 'A nonempty session ID is required for Acquire and Release.'
    }
    $lock = Enter-AiLock $StateDirectory
    try {
        $state = Read-AiState $StateDirectory
        $pausedPath = Join-Path $StateDirectory 'paused.json'
        $paused = @()
        if ([IO.File]::Exists($pausedPath)) {
            $paused = @([IO.File]::ReadAllText($pausedPath) | ConvertFrom-Json -AsHashtable |
                Where-Object { Test-AiProcessIdentity $_.owner })
        }
        if ($Action -eq 'Release') {
            $paused = @($paused | Where-Object { $_.session -cne $SessionId })
        }
        if ($Action -eq 'Pause') {
            if (-not $state -or $state.token -cne $ExpectedToken) { return }
            $paused = @($paused) + @($state.leases)
        }
        if ($paused.Count) {
            [IO.File]::WriteAllText($pausedPath, (ConvertTo-Json -InputObject $paused -Depth 10))
        }
        else { [IO.File]::Delete($pausedPath) }
        if ($Action -eq 'Status') {
            return @{
                activeScheme = Get-AiActiveScheme
                recovery = $state
                pausedSessions = $paused.Count
                watchdogAlive = ($null -ne $state -and (Test-AiProcessIdentity $state.watchdog))
            }
        }
        if ($Action -in @('Restore', 'Pause')) {
            if ($state) { Restore-AiScheme $StateDirectory $state }
            return
        }
        if ($state) {
            $state.leases = @($state.leases | Where-Object { Test-AiProcessIdentity $_.owner })
            if ($state.phase -ne 'active' -or $state.leases.Count -eq 0 -or
                -not (Test-AiProcessIdentity $state.watchdog)) {
                Restore-AiScheme $StateDirectory $state
                $state = $null
            }
        }
        if ($Action -eq 'Release') {
            if ($state) {
                $state.leases = @($state.leases | Where-Object { $_.session -cne $SessionId })
                if ($state.leases.Count -eq 0) { Restore-AiScheme $StateDirectory $state }
                else { Write-AiState $StateDirectory $state }
            }
            return
        }
        if (@($paused | Where-Object { $_.session -ceq $SessionId }).Count) { return }
        if ($state) {
            # Refresh the owner after a session is resumed in another runtime.
            $lease = @{ session = $SessionId; owner = (Get-AiOwnerIdentity) }
            $state.leases = @($state.leases | Where-Object { $_.session -cne $SessionId }) + @($lease)
            Write-AiState $StateDirectory $state
            return
        }
        $state = @{
            version = 1
            phase = 'preparing'
            original = Get-AiActiveScheme
            temporary = [guid]::NewGuid().ToString()
            leases = @(@{ session = $SessionId; owner = (Get-AiOwnerIdentity) })
            watchdog = $null
            token = [guid]::NewGuid().ToString('N')
        }
        # Journal before any power mutation, including creation of the temporary plan.
        Write-AiState $StateDirectory $state
        try {
            $state.watchdog = Start-AiWatchdog $StateDirectory $state.token
            Write-AiState $StateDirectory $state
            $null = Invoke-AiPowerCfg -Arguments @('/duplicatescheme', $state.original, $state.temporary)
            $null = Invoke-AiPowerCfg -Arguments @('/changename', $state.temporary, 'AwakeMate (temporary)')
            foreach ($mode in @('/setacvalueindex', '/setdcvalueindex')) {
                foreach ($setting in @('STANDBYIDLE', 'HIBERNATEIDLE', '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0')) {
                    $null = Invoke-AiPowerCfg -Arguments @($mode, $state.temporary, 'SUB_SLEEP', $setting, '0')
                }
                $null = Invoke-AiPowerCfg -Arguments @($mode, $state.temporary, 'SUB_BUTTONS', '5ca83367-6e45-459f-a27b-476b1d01c936', '0')
            }
            $null = Invoke-AiPowerCfg -Arguments @('/setactive', $state.temporary)
            if ((Get-AiActiveScheme) -ne $state.temporary) { throw 'Windows did not activate the temporary power plan.' }
            $state.phase = 'active'
            Write-AiState $StateDirectory $state
        }
        catch {
            $failure = $_
            try { Restore-AiScheme $StateDirectory $state }
            catch { throw "Acquisition failed: $failure Recovery also failed: $_. Run the restore command." }
            throw $failure
        }
    }
    finally { $lock.Dispose() }
}

function Invoke-AiWatchdogTick {
    param([string] $Directory, [string] $Token, $TrayIcon)
    $lock = Enter-AiLock $Directory
    try {
        $state = Read-AiState $Directory
        if (-not $state -or $state.token -cne $Token) {
            if ($TrayIcon) { $TrayIcon.Visible = $false }
            return $false
        }
        $state.leases = @($state.leases | Where-Object { Test-AiProcessIdentity $_.owner })
        if ($state.phase -ne 'active' -or $state.leases.Count -eq 0) {
            if ($TrayIcon) { $TrayIcon.Visible = $false }
            Restore-AiScheme $Directory $state
            return $false
        }
        Write-AiState $Directory $state
        if ($TrayIcon) {
            $TrayIcon.Text = "AwakeMate active - $($state.leases.Count) session(s)"
            $TrayIcon.Visible = (Get-AiActiveScheme) -eq $state.temporary
        }
        return $true
    }
    finally { $lock.Dispose() }
}

function New-AiTrayIcon {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $icon = [System.Windows.Forms.NotifyIcon]::new()
    $icon.Icon = [System.Drawing.Icon]::new((Join-Path $PSScriptRoot 'awakemate.ico'))
    $icon.Text = 'AwakeMate'
    $icon.Visible = $false
    $icon.Tag = [pscustomobject] @{ StopRequested = $false }
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    $stop = $menu.Items.Add('Stop for current turns')
    $stop.add_Click({ $this.Owner.Tag.StopRequested = $true })
    $menu.Tag = $icon.Tag
    $icon.ContextMenuStrip = $menu
    $icon.add_MouseClick({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $this.ContextMenuStrip.Show([System.Windows.Forms.Cursor]::Position)
        }
    })
    $icon
}

function Invoke-AwakeMateWatchdog {
    param([string] $StateDirectory, [string] $Token)
    $ready = Join-Path $StateDirectory "ready-$Token"
    $trayIcon = New-AiTrayIcon
    try {
        if ($trayIcon.Tag.StopRequested) {
            Invoke-AwakeMate -Action Pause -ExpectedToken $Token -StateDirectory $StateDirectory
            $trayIcon.Visible = $false
            break
        }
        [IO.File]::WriteAllText($ready, $PID.ToString())
        while ($true) {
            try {
                if (-not (Invoke-AiWatchdogTick $StateDirectory $Token $trayIcon)) { break }
            }
            catch {
                $trayIcon.Visible = $false
                $trayIcon.ContextMenuStrip.Dispose()
                $trayIcon.Icon.Dispose()
                $message = "$(Get-Date -Format o) Recovery watchdog: $_"
                [IO.File]::AppendAllText((Join-Path $StateDirectory 'recovery.log'), "$message`r`n")
                [Console]::Error.WriteLine($message)
            }
            $wait = [Diagnostics.Stopwatch]::StartNew()
            while ($wait.Elapsed.TotalSeconds -lt 5) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
        }
    }
    finally {
        $trayIcon.Visible = $false
        $trayIcon.Dispose()
        [IO.File]::Delete($ready)
    }
}

Export-ModuleMember -Function Invoke-AwakeMate, Invoke-AwakeMateWatchdog

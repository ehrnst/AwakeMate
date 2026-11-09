#requires -Version 7.2
param([switch] $TestPluginInstallation)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$module = Import-Module (Join-Path $root 'scripts\AwakeMate.psm1') -Force -PassThru
$temporary = Join-Path ([IO.Path]::GetTempPath()) "AwakeMate tests-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($temporary)
try {
    & $module {
        param($Directory)
        $script:testDirectory = $Directory
        $script:original = '11111111-1111-1111-1111-111111111111'
        $script:manual = '22222222-2222-2222-2222-222222222222'
        $script:passed = 0
        $script:realStartWatchdog = ${function:Start-AiWatchdog}

        function Assert-True {
            param([bool] $Condition, [string] $Message)
            if (-not $Condition) { throw "Assertion failed: $Message" }
        }

        function Assert-Throws {
            param([scriptblock] $Run, [string] $Pattern)
            try { & $Run }
            catch {
                if ("$_" -notlike "*$Pattern*") { throw "Expected '$Pattern', got: $_" }
                return
            }
            throw "Expected an exception containing '$Pattern'."
        }

        function Reset-Test {
            $script:caseDirectory = Join-Path $script:testDirectory ([guid]::NewGuid().ToString('N'))
            $null = [IO.Directory]::CreateDirectory($script:caseDirectory)
            $script:fake = @{
                active = $script:original
                plans = @{ $script:original = @{}; $script:manual = @{} }
                calls = [Collections.Generic.List[object]]::new()
                alive = @{ '101' = '1'; '102' = '2'; '9001' = '3' }
                owner = @{ pid = 101; started = '1' }
                fail = ''
                watchdogFailure = $false
                watchdogStarts = 0
                failRecovery = $false
            }
        }

        function script:Get-AiOwnerIdentity { $script:fake.owner }

        function script:Test-AiProcessIdentity {
            param([hashtable] $Identity)
            $null -ne $Identity -and $script:fake.alive[[string] $Identity.pid] -ceq $Identity.started
        }

        function script:Start-AiWatchdog {
            param([string] $Directory, [string] $Token)
            $script:fake.watchdogStarts++
            if ($script:fake.watchdogFailure) { throw 'Simulated watchdog startup failure' }
            $script:fake.alive['9001'] = '3'
            @{ pid = 9001; started = '3' }
        }

        function script:Invoke-AiPowerCfg {
            param([string[]] $Arguments)
            $script:fake.calls.Add($Arguments)
            $verb = $Arguments[0]
            if ($verb -eq $script:fake.fail) {
                $script:fake.fail = ''
                throw "Simulated powercfg $verb failure"
            }
            if ($verb -notin @('/getactivescheme', '/list')) {
                Assert-True ([IO.File]::Exists((Join-Path $script:caseDirectory 'state.json'))) 'journal exists before mutation'
            }
            switch ($verb) {
                '/getactivescheme' { return "Power Scheme GUID: $($script:fake.active) (localized name)" }
                '/list' { return $script:fake.plans.Keys -join "`n" }
                '/duplicatescheme' {
                    Assert-True ($Arguments.Count -eq 3) 'duplicate arguments are preserved'
                    Assert-True ($script:fake.plans.ContainsKey($Arguments[1])) 'source plan exists'
                    $script:fake.plans[$Arguments[2]] = $script:fake.plans[$Arguments[1]].Clone()
                }
                '/changename' { Assert-True ($Arguments.Count -eq 3) 'name arguments are preserved' }
                { $_ -in @('/setacvalueindex', '/setdcvalueindex') } {
                    Assert-True ($Arguments.Count -eq 5) 'setting arguments are preserved'
                    $script:fake.plans[$Arguments[1]][($Arguments[0, 2, 3] -join ':')] = $Arguments[4]
                }
                '/setactive' {
                    if ($script:fake.failRecovery -and $Arguments[1] -eq $script:original) {
                        throw 'Simulated recovery failure'
                    }
                    Assert-True ($script:fake.plans.ContainsKey($Arguments[1])) 'activated plan exists'
                    $script:fake.active = $Arguments[1]
                }
                '/delete' {
                    Assert-True ($script:fake.active -ne $Arguments[1]) 'never delete the active plan'
                    $script:fake.plans.Remove($Arguments[1])
                }
                default { throw "Unexpected powercfg call: $Arguments" }
            }
            ''
        }

        function Acquire {
            param([string] $Session = 'one')
            Invoke-AwakeMate Acquire -SessionId $Session -StateDirectory $script:caseDirectory
        }
        function Release {
            param([string] $Session = 'one')
            Invoke-AwakeMate Release -SessionId $Session -StateDirectory $script:caseDirectory
        }
        function State { Read-AiState $script:caseDirectory }
        function Tick { Invoke-AiWatchdogTick $script:caseDirectory (State).token }
        function Test-Case {
            param([string] $Name, [scriptblock] $Run)
            Reset-Test
            & $Run
            $script:passed++
            Write-Host "PASS $Name"
        }

        Test-Case 'AC/DC sleep, hibernation, unattended sleep, and lid settings are zero on a duplicate' {
            Acquire
            $state = State
            Assert-True ($state.phase -eq 'active') 'activation is committed'
            Assert-True ($script:fake.active -eq $state.temporary) 'temporary plan is active'
            $settings = $script:fake.plans[$state.temporary]
            Assert-True ($settings.Count -eq 8) 'exactly four settings on AC and DC'
            foreach ($mode in @('/setacvalueindex', '/setdcvalueindex')) {
                foreach ($setting in @('STANDBYIDLE', 'HIBERNATEIDLE', '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0')) {
                    Assert-True ($settings["${mode}:SUB_SLEEP:$setting"] -eq '0') "$mode $setting is never"
                }
                Assert-True ($settings["${mode}:SUB_BUTTONS:5ca83367-6e45-459f-a27b-476b1d01c936"] -eq '0') "$mode lid action is do nothing"
            }
            Assert-True ($script:fake.plans[$script:original].Count -eq 0) 'original plan is untouched'
            Release
            Assert-True ($script:fake.active -eq $script:original) 'original plan is restored'
            Assert-True ($null -eq (State)) 'journal is removed after recovery'
            Assert-True (-not $script:fake.plans.ContainsKey($state.temporary)) 'temporary plan is deleted'
        }

        Test-Case 'normal AC and battery lid actions survive overlapping agent turns unchanged' {
            $ac = '/setacvalueindex:SUB_BUTTONS:5ca83367-6e45-459f-a27b-476b1d01c936'
            $dc = '/setdcvalueindex:SUB_BUTTONS:5ca83367-6e45-459f-a27b-476b1d01c936'
            $script:fake.plans[$script:original][$ac] = '2'
            $script:fake.plans[$script:original][$dc] = '1'
            Acquire one
            Acquire two
            $active = $script:fake.plans[$script:fake.active]
            Assert-True ($active[$ac] -eq '0' -and $active[$dc] -eq '0') 'both lid actions are do nothing during agent work'
            Release one
            Assert-True ($script:fake.active -ne $script:original) 'remaining agent retains temporary protection'
            Release two
            $active = $script:fake.plans[$script:fake.active]
            Assert-True ($script:fake.active -eq $script:original) 'last agent restores the original plan'
            Assert-True ($active[$ac] -eq '2') 'normal AC hibernate action is preserved'
            Assert-True ($active[$dc] -eq '1') 'normal battery sleep action is preserved'
        }

        Test-Case 'multiple sessions, repeated acquire, and repeated release are safe' {
            Acquire one
            Acquire one
            $script:fake.owner = @{ pid = 102; started = '2' }
            Acquire two
            Assert-True ((State).leases.Count -eq 2) 'one lease per session'
            Assert-True ($script:fake.watchdogStarts -eq 1) 'one watchdog per plan'
            Release one
            Release one
            Assert-True ((State).leases.Count -eq 1) 'other session stays protected'
            Release two
            Release two
            Assert-True ($null -eq (State)) 'last session triggers recovery'
        }

        Test-Case 'session IDs are case sensitive and unknown releases do not release others' {
            Acquire One
            Acquire one
            Release other
            Assert-True ((State).leases.Count -eq 2) 'unknown release does not change leases'
            Release One
            Assert-True ((State).leases[0].session -ceq 'one') 'case-distinct session is retained'
        }

        Test-Case 'watchdog prunes dead owners and restores after the final owner exits' {
            Acquire one
            $script:fake.owner = @{ pid = 102; started = '2' }
            Acquire two
            $script:fake.alive.Remove('101')
            Assert-True (Tick) 'watchdog continues while one owner lives'
            Assert-True ((State).leases.Count -eq 1) 'dead owner is pruned'
            $script:fake.alive.Remove('102')
            Assert-True (-not (Tick)) 'watchdog exits after recovery'
            Assert-True ($script:fake.active -eq $script:original) 'original is restored after crash'
        }

        Test-Case 'PID reuse is not mistaken for a live owner' {
            Acquire
            $script:fake.alive['101'] = 'new-process-start-time'
            Assert-True (-not (Tick)) 'reused PID loses its lease'
        }

        Test-Case 'a previous watchdog cannot restore a newer generation' {
            Acquire
            Assert-True (-not (Invoke-AiWatchdogTick $script:caseDirectory 'obsolete')) 'old generation exits'
            Assert-True ((State).phase -eq 'active') 'current generation is untouched'
        }

        Test-Case 'manual plan selection wins over original-plan restoration' {
            Acquire
            $script:fake.active = $script:manual
            Release
            Assert-True ($script:fake.active -eq $script:manual) 'manual choice is preserved'
            Assert-True ($null -eq (State)) 'temporary plan cleanup completes'
        }

        Test-Case 'configuration failure rolls back without modifying the original' {
            $script:fake.fail = '/setdcvalueindex'
            Assert-Throws { Acquire } 'Simulated powercfg'
            Assert-True ($script:fake.active -eq $script:original) 'original stays active'
            Assert-True ($script:fake.plans.Count -eq 2) 'partial duplicate is deleted'
            Assert-True ($null -eq (State)) 'rollback completes'
        }

        Test-Case 'watchdog startup failure prevents all plan mutations' {
            $script:fake.watchdogFailure = $true
            Assert-Throws { Acquire } 'watchdog startup failure'
            Assert-True ($script:fake.plans.Count -eq 2) 'no temporary plan created'
            Assert-True ($script:fake.active -eq $script:original) 'original stays active'
        }

        Test-Case 'failed restoration keeps the journal and can be retried' {
            Acquire
            $script:fake.failRecovery = $true
            Assert-Throws { Release } 'recovery failure'
            Assert-True ((State).phase -eq 'restoring') 'journal survives failed recovery'
            $script:fake.failRecovery = $false
            Invoke-AwakeMate Restore -StateDirectory $script:caseDirectory
            Assert-True ($null -eq (State)) 'explicit recovery retries successfully'
        }

        Test-Case 'interrupted preparing phase is recovered before the next acquire' {
            Acquire
            $old = State
            $old.phase = 'preparing'
            Write-AiState $script:caseDirectory $old
            Acquire
            Assert-True ((State).temporary -ne $old.temporary) 'fresh plan is used'
            Assert-True ((State).original -eq $script:original) 'temporary plan is not captured as the original'
        }

        Test-Case 'dead watchdog is replaced and a missing stop is recovered on the next acquire' {
            Acquire
            $old = State
            $script:fake.alive.Remove('9001')
            Acquire two
            Assert-True (-not $script:fake.plans.ContainsKey($old.temporary)) 'old temporary plan is removed'
            Assert-True ((State).original -eq $script:original) 'original plan is preserved'
        }

        Test-Case 'corrupt recovery state fails explicitly and never changes power' {
            [IO.File]::WriteAllText((Join-Path $script:caseDirectory 'state.json'), '{broken')
            Assert-Throws { Acquire } 'Conversion from JSON failed'
            Assert-True ($script:fake.calls.Count -eq 0) 'corrupt state is not discarded'
        }

        Test-Case 'empty session IDs fail before any mutation' {
            Assert-Throws { Acquire ' ' } 'nonempty session ID'
            Assert-True ($script:fake.calls.Count -eq 0) 'invalid input never reaches powercfg'
        }

        Test-Case 'status reports state without power mutations; manual recovery overrides all leases' {
            Acquire
            $status = Invoke-AwakeMate Status -StateDirectory $script:caseDirectory
            Assert-True $status.watchdogAlive 'watchdog liveness is reported'
            Assert-True ($status.recovery.leases.Count -eq 1) 'leases are visible'
            Invoke-AwakeMate Restore -StateDirectory $script:caseDirectory
            Assert-True ($script:fake.active -eq $script:original) 'explicit restore ends active leases'
        }

        Test-Case 'tray reflects active protection, overlapping sessions, manual changes, and restoration' {
            $tray = [pscustomobject] @{ Visible = $false; Text = '' }
            Acquire one
            Acquire two
            $token = (State).token
            Assert-True (Invoke-AiWatchdogTick $script:caseDirectory $token $tray) 'watchdog continues'
            Assert-True $tray.Visible 'tray is visible for the active temporary plan'
            Assert-True ($tray.Text -eq 'AwakeMate active - 2 session(s)') 'tooltip reports protected sessions'
            Release one
            $null = Invoke-AiWatchdogTick $script:caseDirectory $token $tray
            Assert-True ($tray.Visible -and $tray.Text -eq 'AwakeMate active - 1 session(s)') 'remaining session stays visible'
            $script:fake.active = $script:manual
            $null = Invoke-AiWatchdogTick $script:caseDirectory $token $tray
            Assert-True (-not $tray.Visible) 'manual power-plan selection hides the active indicator'
            Release two
            Assert-True (-not (Invoke-AiWatchdogTick $script:caseDirectory $token $tray)) 'watchdog exits after release'
            Assert-True (-not $tray.Visible) 'tray is hidden after restoration'
        }

        Test-Case 'stale watchdog hides its tray without disturbing the current generation' {
            Acquire
            $tray = [pscustomobject] @{ Visible = $true; Text = 'Old generation' }
            Assert-True (-not (Invoke-AiWatchdogTick $script:caseDirectory 'obsolete' $tray)) 'stale watchdog exits'
            Assert-True (-not $tray.Visible) 'stale icon is hidden'
        }

        Test-Case 'Windows tray icon can be initialized and disposed' {
            $tray = New-AiTrayIcon
            try {
                Assert-True ($tray -is [System.Windows.Forms.NotifyIcon]) 'real Windows tray component is created'
                Assert-True (-not $tray.Visible) 'no active indicator before activation'
                Assert-True ($null -ne $tray.Icon) 'tray has an icon'
                Assert-True ($tray.Icon.Width -eq 256) 'packaged SVG-derived icon is loaded'
                Assert-True ($tray.ContextMenuStrip.Items[0].Text -eq 'Stop for current turns') 'stop action is present'
                $tray.ContextMenuStrip.Items[0].PerformClick()
                Assert-True $tray.Tag.StopRequested 'click requests a stop without touching power settings inside the UI callback'
            }
            finally {
                $tray.ContextMenuStrip.Dispose()
                $tray.Icon.Dispose()
                $tray.Dispose()
            }
        }

        Test-Case 'tray stop restores settings and suppresses only currently running turns until release' {
            Acquire one
            Acquire two
            $token = (State).token
            Invoke-AwakeMate Pause -ExpectedToken $token -StateDirectory $script:caseDirectory
            Assert-True ($script:fake.active -eq $script:original) 'stop restores normal power immediately'
            Acquire one
            Acquire two
            Assert-True ($null -eq (State)) 'tool hooks cannot reactivate stopped turns'
            Acquire three
            Assert-True ($null -ne (State)) 'new unrelated session can acquire protection'
            Release three
            Release one
            Acquire one
            Assert-True ($null -ne (State)) 'released session can start another turn'
            Release one
            Release two
            Assert-True (-not [IO.File]::Exists((Join-Path $script:caseDirectory 'paused.json'))) 'pause state is cleared'
        }

        Test-Case 'stale tray stop cannot pause a newer generation' {
            Acquire
            Invoke-AwakeMate Pause -ExpectedToken obsolete -StateDirectory $script:caseDirectory
            Assert-True ((State).phase -eq 'active') 'current protection is unaffected'
        }

        Test-Case 'plugin uses the copilot-AwakeMate recovery-state directory' {
            $expected = Join-Path $env:LOCALAPPDATA 'copilot-AwakeMate'
            Assert-True ((Get-AiStateDirectory) -eq $expected) 'recovery state uses the product directory'
        }

        Test-Case 'real watchdog signals readiness, waits for the lock, and exits without recovery state' {
            $lock = Enter-AiLock $script:caseDirectory
            $identity = $null
            try {
                $identity = & $script:realStartWatchdog $script:caseDirectory ([guid]::NewGuid().ToString('N'))
                Assert-True ($null -ne (Get-Process -Id $identity.pid -ErrorAction Ignore)) 'watchdog is responsive and running'
                Assert-Throws {
                    $other = [IO.File]::Open((Join-Path $script:caseDirectory 'state.lock'), 'Open', 'ReadWrite', 'None')
                    $other.Dispose()
                } 'being used by another process'
            }
            finally {
                $lock.Dispose()
                if ($identity) {
                    $process = Get-Process -Id $identity.pid -ErrorAction Ignore
                    if ($process -and -not $process.WaitForExit(10000)) {
                        Stop-Process -Id $identity.pid
                        throw 'Watchdog did not exit after finding no state.'
                    }
                }
            }
        }
        Write-Host "$script:passed lifecycle tests passed."
    } $temporary

    $files = Get-ChildItem (Join-Path $root 'scripts'), $PSScriptRoot -Recurse -File |
        Where-Object Extension -in '.ps1', '.psm1'
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors)
        if ($errors.Count) { throw "$($file.Name): $errors" }
    }
    $manifest = Get-Content (Join-Path $root 'plugin.json') -Raw | ConvertFrom-Json
    if ($manifest.name -ne 'awakemate' -or $manifest.hooks -ne 'hooks/hooks.json') { throw 'Invalid plugin manifest.' }
    $hooks = Get-Content (Join-Path $root 'hooks\hooks.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($hooks.version -ne 1 -or $hooks.hooks.Count -ne 4) { throw 'Invalid hook manifest.' }
    foreach ($event in $hooks.hooks.Keys) {
        $hook = $hooks.hooks[$event][0]
        if ($hook.powershell -notmatch '\$\{PLUGIN_ROOT\}\\scripts\\hook.ps1') { throw "Invalid plugin-relative command for $event." }
        if ($hook.ContainsKey('bash') -or $hook.ContainsKey('command')) { throw 'Hooks must be Windows-only.' }
    }

    $hookScript = Join-Path $root 'scripts\hook.ps1'
    $output = '{"sessionId":"test","agentId":"subagent"}' | & pwsh -NoLogo -NoProfile -File $hookScript -Event Release
    if ($LASTEXITCODE -ne 0 -or $output -ne '{}') { throw 'Subagent stop must not release its parent lease.' }
    $output = '{}' | & pwsh -NoLogo -NoProfile -File $hookScript -Event Acquire 2>&1
    if ($LASTEXITCODE -ne 1 -or "$output" -notmatch 'sessionId') { throw 'Invalid hook payload must fail explicitly.' }
    Write-Host 'PASS script syntax, plugin manifests, subagent isolation, and hook input validation'

    if ($TestPluginInstallation) {
        $null = Get-Command copilot -ErrorAction Stop
        $previousHome = $env:COPILOT_HOME
        $env:COPILOT_HOME = Join-Path $temporary 'copilot profile'
        $null = [IO.Directory]::CreateDirectory($env:COPILOT_HOME)
        try {
            $output = & copilot plugin install $root 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Plugin installation failed: $output" }
            $output = & copilot plugin list 2>&1
            if ($LASTEXITCODE -ne 0 -or "$output" -notmatch '\bawakemate\b') {
                throw "Expected the directly installed plugin: $output"
            }
            $installedHooks = @(Get-ChildItem -LiteralPath $env:COPILOT_HOME -Recurse -Filter hook.ps1)
            if ($installedHooks.Count -ne 1) { throw 'Installed plugin is missing its hook entry point.' }
            if (-not (Test-Path -LiteralPath (Join-Path $installedHooks[0].DirectoryName 'awakemate.ico'))) {
                throw 'Installed plugin is missing its SVG-derived tray icon.'
            }
            $output = & copilot plugin uninstall awakemate 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Plugin uninstall failed: $output" }
            $output = & copilot plugin list 2>&1
            if ($LASTEXITCODE -ne 0 -or "$output" -match '\bawakemate\b') {
                throw "Plugin remained installed after uninstall: $output"
            }
            Write-Host 'PASS direct plugin installation, hook packaging, listing, and uninstall in an isolated profile'
        }
        finally { $env:COPILOT_HOME = $previousHome }
    }
}
finally {
    Remove-Module $module -Force
    # Only delete this run's explicitly created, randomly named test directory.
    Remove-Item -LiteralPath $temporary -Recurse -Force
}

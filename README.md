# AwakeMate

![AwakeMate logo](awakemate.jpg)

AwakeMate keeps a Windows PC awake while GitHub Copilot works, then restores
your power plan. It creates a temporary copy and never edits your original plan
or requests administrator privileges. Created because i wanted to and because other solutions looked a bit over engineered.

## Requirements

- Windows with Copilot running locally (WSL and remote Linux are unsupported).
- PowerShell 7.2 or newer.
- Copilot CLI or VS Code with agent-plugin command-hook support.
- Permission to create and activate power schemes; device policy may block it.

Hooks run scripts on your computer. Review the [PowerShell scripts](scripts/)
before installing.

## Install

Install with Copilot CLI:

```powershell
copilot plugin install ehrnst/AwakeMate
```

Or install `https://github.com/ehrnst/AwakeMate` in VS Code's Agent
Customizations editor and select the **Copilot** harness. Confirm that all four
hooks appear. Support depends on your VS Code, Copilot, and organization
settings.

Restart Copilot and start a new agent session. Installation alone does not
change power settings. Do not register the hooks again in workspace or user
settings; duplicate registrations can run scripts more than once.

## How it works

When an agent turn starts, AwakeMate saves recovery state, starts a watchdog,
and activates a copy of your current power plan. The copy disables idle sleep,
hibernation, unattended sleep, and lid-close actions on AC and battery. When
all active sessions finish, AwakeMate restores your original plan and deletes
the copy. If you select another plan while AwakeMate runs, your selection takes
precedence.

Concurrent sessions share recovery state. A watchdog checks every five seconds
and clears leases for stopped runtimes. The tray icon shows whether protection
is active and how many sessions use it. Select **Stop for current turns** from
the icon menu to restore normal power settings. Hooks from those turns won't
reactivate protection; later turns can.

## Status and recovery

Run these commands from a checkout or the installed plugin folder:

```powershell
pwsh -NoProfile -File .\scripts\manage.ps1 -Action Status
pwsh -NoProfile -File .\scripts\manage.ps1 -Action Restore
```

`Status` reports the active plan and recovery state. `Restore` ends all leases
and removes the temporary plan. Disable or uninstall the plugin first to stop
new hooks from acquiring leases.

AwakeMate stores recovery data in `%LOCALAPPDATA%\copilot-AwakeMate`. It reports
hook errors on stderr and logs watchdog errors to `recovery.log`. If recovery
fails, it keeps the journal so you can retry. **Do not delete the journal
before restoring.** If it is damaged, use its `original` GUID with
`powercfg /setactive <original-guid>` and delete only the recorded temporary
plan after verifying recovery.

## Limitations

- AwakeMate protects active agent turns, not idle chat windows. It ignores
  subagent events; a subagent stays protected only while its parent turn runs.
- If cancellation skips cleanup hooks, or a shared VS Code/Node host survives a
  session crash, run `Restore`.
- A reboot, OS crash, or forced termination can stop the watchdog. AwakeMate
  does not install a logon task; run `Restore` or start another hook to recover.
- AwakeMate does not disable display timeout, screen locking, explicit
  Sleep/Hibernate commands, critical-battery actions, or thermal protections.
  Windows or hardware may still suspend or shut down the PC.
- Keeping a laptop awake drains its battery. Keep it ventilated; never put an
  awake, closed-lid laptop in a bag.

## Uninstall

Stop agent work, restore the plan, then uninstall:

```powershell
pwsh -NoProfile -File .\scripts\manage.ps1 -Action Restore
copilot plugin uninstall awakemate
```

If `copilot plugin list` shows a qualified plugin name, use that exact name.

## Development

Run from a checkout without installing:

```powershell
copilot --plugin-dir (Get-Location).Path
```

Run the test suite:

```powershell
pwsh -NoLogo -NoProfile -File .\tests\Run-Tests.ps1
```

Optionally test packaging in an isolated `COPILOT_HOME`:

```powershell
pwsh -NoLogo -NoProfile -File .\tests\Run-Tests.ps1 -TestPluginInstallation
```

The packaged `scripts/awakemate.ico` comes from `awakemate.svg`. To rebuild it,
run `pwsh -NoProfile -File .\scripts\Build-TrayIcon.ps1 -BrowserPath <path>`
with a Chromium headless renderer.

## References

- [Copilot hooks](https://docs.github.com/en/copilot/reference/hooks-reference)
- [Copilot plugins](https://docs.github.com/en/copilot/reference/cli-plugin-reference)
- [VS Code agent plugins](https://code.visualstudio.com/docs/agents/reference/agent-plugin-reference)
- [Windows `powercfg`](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options)

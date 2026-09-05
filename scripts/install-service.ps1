<#
  Installs the Notables note server as a Windows Scheduled Task plus the firewall
  rule that lets the Mac reach it over Tailscale.  Run once, elevated:

      powershell -NoProfile -ExecutionPolicy Bypass -File install-service.ps1

  The task runs AS KIERAN, not SYSTEM: the claude CLI authenticates against his
  Claude subscription using credentials stored in his user profile, so a SYSTEM
  task could not run the AI pass at all.

  Two triggers:
    * at logon              - comes back after a reboot
    * every 2 minutes       - watchdog; run-server.cmd exits immediately when the
                              port is already listening, so this is a no-op unless
                              the server died.
#>
[CmdletBinding()]
param(
  [string]$ServerDir = "$env:USERPROFILE\Notables\server",
  [string]$TaskName  = 'Notables Note Server',
  [int]   $Port      = 8787,
  [string]$RemoteIp  = '100.64.0.0/10'   # Tailscale CGNAT range only
)

$ErrorActionPreference = 'Stop'
# USERDOMAIN is "WORKGROUP" on a machine that isn't domain-joined, and that does not
# resolve to a SID - use the machine name, and keep the SID as a fallback.
$user = "$env:COMPUTERNAME\$env:USERNAME"
$sid  = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
try   { $null = (New-Object System.Security.Principal.NTAccount($user)).Translate([System.Security.Principal.SecurityIdentifier]) }
catch { Write-Host "  '$user' did not resolve, falling back to SID $sid"; $user = $sid }
$vbs  = Join-Path $ServerDir 'start-hidden.vbs'

if (-not (Test-Path $vbs)) { throw "launcher not found: $vbs (deploy the server first)" }

Write-Host "Registering scheduled task '$TaskName' for $user"
Write-Host "  launcher: $vbs"

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B //Nologo "{0}"' -f $vbs)

$tLogon  = New-ScheduledTaskTrigger -AtLogOn -User $user
$tWatch  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
             -RepetitionInterval (New-TimeSpan -Minutes 2)

$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
  -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $tLogon,$tWatch `
  -Principal $principal -Settings $settings -Description 'Notables note server (Node, port 8787)' -Force | Out-Null

Write-Host "  task registered"

# ------------------------------------------------------------------ firewall
$ruleName = "Notables Note Server $Port"
$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($existing) { $existing | Remove-NetFirewallRule }
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort $Port -RemoteAddress $RemoteIp -Profile Any `
  -Description 'Notables: inbound from the Tailscale subnet only' | Out-Null
Write-Host "  firewall rule '$ruleName' allows TCP $Port from $RemoteIp"

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3
Write-Host ''
Write-Host (Get-ScheduledTask -TaskName $TaskName | Format-List TaskName,State | Out-String)

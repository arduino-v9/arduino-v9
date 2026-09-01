$ErrorActionPreference = 'Stop'
$RequestedAction = if ($env:ARDUINO_ACTION) { $env:ARDUINO_ACTION.ToLowerInvariant() } else { 'install' }
$env:FMV4_SELF = $PSCommandPath
$env:FIVEM_V2_SELF = $PSCommandPath

$v8Source = @'
$ErrorActionPreference = 'Stop'
$Action = [string]$env:FMV4_ACTION
$SelfPath = [string]$env:FMV4_SELF
$DataDirectory = Join-Path $env:ProgramData 'FiveM-Session-V4-Universal'
$WatcherPath = Join-Path $DataDirectory 'FiveM-Session-Watcher.ps1'
$RuntimeState = Join-Path $DataDirectory 'runtime-state.clixml'
$GpuState = Join-Path $DataDirectory 'gpu-preferences.clixml'
$WatcherLog = Join-Path $DataDirectory 'watcher.log'
$ProfileGuidFile = Join-Path $DataDirectory 'profile-guid.txt'
$TaskName = 'FiveM Session V4 MAX Universal'
$QosPrefix = 'FiveM-SessionV4-'
$ErrorLog = Join-Path $env:TEMP 'HIY_ARDUINO_FIVEM_V5_Last_Error.log'

trap {
    $record = $_
    $details = @(
        'Arduino V8 Adaptive MAX - unhandled error'
        ('Time: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        ('Action: {0}' -f $Action)
        ('Message: {0}' -f $record.Exception.Message)
        ('Position: {0}' -f $record.InvocationInfo.PositionMessage)
        ''
        ($record | Format-List * -Force | Out-String)
    ) -join [Environment]::NewLine
    try { Set-Content -LiteralPath $ErrorLog -Value $details -Encoding UTF8 -Force } catch {}
    Write-Host
    Write-Host 'HIY ARDUINO V6 MAX STOPPED ON AN ERROR' -ForegroundColor Red
    Write-Host ('Message: {0}' -f $record.Exception.Message) -ForegroundColor Red
    Write-Host ('Log: {0}' -f $ErrorLog) -ForegroundColor Yellow
    exit 1
}

function Write-Title {
    Clear-Host
    $Host.UI.RawUI.WindowTitle = 'Arduino'
    Write-Host
    Write-Host '   ARDUINO' -ForegroundColor Green
    Write-Host '   FiveM  |  ADAPTIVE LOW LATENCY' -ForegroundColor DarkGray
    Write-Host '   ------------------------' -ForegroundColor DarkGray
    Write-Host
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Administrator([string]$RequestedAction) {
    if (Test-Administrator) { return $true }
    Write-Host 'Requesting Administrator permission...' -ForegroundColor Yellow
    $arguments = '/d /c ""{0}" {1}"' -f $SelfPath, $RequestedAction
    try {
        Start-Process -FilePath $env:ComSpec -Verb RunAs -ArgumentList $arguments | Out-Null
    } catch {
        Write-Host 'Administrator permission was not granted.' -ForegroundColor Red
        Read-Host '   Enter to close'
    }
    return $false
}

function Get-WatcherSource {
    return @'
$ErrorActionPreference = 'SilentlyContinue'
$dataDirectory = Join-Path $env:ProgramData 'FiveM-Session-V4-Universal'
$runtimeState = Join-Path $dataDirectory 'runtime-state.clixml'
$gpuState = Join-Path $dataDirectory 'gpu-preferences.clixml'
$watcherLog = Join-Path $dataDirectory 'watcher.log'
$profileGuidFile = Join-Path $dataDirectory 'profile-guid.txt'
$qosPrefix = 'FiveM-SessionV4-'
$gpuKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$active = $false
$missingCycles = 0
$knownProcesses = @{}
$sessionPaths = New-Object System.Collections.Generic.HashSet[string]

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class FiveMProcessV4 {
    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORY_PRIORITY_INFORMATION {
        public UInt32 MemoryPriority;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_POWER_THROTTLING_STATE {
        public UInt32 Version;
        public UInt32 ControlMask;
        public UInt32 StateMask;
    }

    [DllImport("kernel32.dll", EntryPoint="SetProcessInformation", SetLastError=true)]
    private static extern bool SetMemoryInformation(
        IntPtr process, int informationClass,
        ref MEMORY_PRIORITY_INFORMATION information, int informationSize);

    [DllImport("kernel32.dll", EntryPoint="SetProcessInformation", SetLastError=true)]
    private static extern bool SetPowerInformation(
        IntPtr process, int informationClass,
        ref PROCESS_POWER_THROTTLING_STATE information, int informationSize);

    public static bool SetNormalMemoryPriority(IntPtr process) {
        MEMORY_PRIORITY_INFORMATION info = new MEMORY_PRIORITY_INFORMATION();
        info.MemoryPriority = 5;
        return SetMemoryInformation(process, 0, ref info, Marshal.SizeOf(info));
    }

    public static bool DisableExecutionSpeedThrottling(IntPtr process) {
        PROCESS_POWER_THROTTLING_STATE info = new PROCESS_POWER_THROTTLING_STATE();
        info.Version = 1;
        // HighQoS plus honor any timer-resolution request made by FiveM.
        info.ControlMask = 3;
        info.StateMask = 0;
        return SetPowerInformation(process, 4, ref info, Marshal.SizeOf(info));
    }
}
"@

function Write-WatcherLog([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $watcherLog -Value $line -Encoding UTF8
    if ((Get-Item -LiteralPath $watcherLog -ErrorAction SilentlyContinue).Length -gt 1048576) {
        Get-Content -LiteralPath $watcherLog -Tail 300 | Set-Content -LiteralPath $watcherLog -Encoding UTF8
    }
}

function Get-ActivePowerGuid {
    $output = (& powercfg.exe /getactivescheme 2>&1 | Out-String)
    $match = [regex]::Match($output, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
    if ($match.Success) { return $match.Value }
    return $null
}

function Get-FiveMProcesses {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -like 'FiveM*' -or $_.ProcessName -like 'CitizenFX*'
    })
}

function Get-RegistryValueState([string]$Path, [string]$Name) {
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $key) {
        return [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $false; Kind = $null; Value = $null }
    }
    try {
        return [pscustomobject]@{
            Path = $Path
            Name = $Name
            Exists = $true
            Kind = $key.GetValueKind($Name).ToString()
            Value = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        }
    } catch {
        return [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $false; Kind = $null; Value = $null }
    }
}

function Restore-RegistryValue($Entry) {
    if (-not $Entry) { return }
    if ([bool]$Entry.Exists) {
        New-Item -Path ([string]$Entry.Path) -Force | Out-Null
        New-ItemProperty -LiteralPath ([string]$Entry.Path) -Name ([string]$Entry.Name) `
            -Value $Entry.Value -PropertyType ([string]$Entry.Kind) -Force | Out-Null
    } else {
        Remove-ItemProperty -LiteralPath ([string]$Entry.Path) -Name ([string]$Entry.Name) `
            -Force -ErrorAction SilentlyContinue
    }
}

function Set-SessionGameSettings {
    # GPEDIT-equivalent policies + MMCSS/Win32 foreground scheduling.
    # Every value is captured before the session and restored when FiveM closes.
    $settings = @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Value = 1; Type = 'DWord' },
        @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AllowAutoGameMode'; Value = 1; Type = 'DWord' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'NetworkThrottlingIndex'; Value = 0xffffffff; Type = 'DWord' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'SystemResponsiveness'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'GPU Priority'; Value = 8; Type = 'DWord' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Priority'; Value = 6; Type = 'DWord' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Scheduling Category'; Value = 'High'; Type = 'String' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'SFIO Priority'; Value = 'High'; Type = 'String' },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'; Name = 'Win32PrioritySeparation'; Value = 0x26; Type = 'DWord' }
    )
    foreach ($setting in $settings) {
        New-Item -Path $setting.Path -Force | Out-Null
        New-ItemProperty -LiteralPath $setting.Path -Name $setting.Name -Value $setting.Value `
            -PropertyType $setting.Type -Force | Out-Null
    }
}

function Get-ActiveAdapterLatencyState {
    $states = @()
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    foreach ($adapter in $adapters) {
        $entry = [ordered]@{
            Name=[string]$adapter.Name; RssSupported=$false; RssEnabled=$null
            RscSupported=$false; RscIPv4=$null; RscIPv6=$null
            InterruptModerationSupported=$false; InterruptModerationName=$null; InterruptModerationValue=$null
        }
        if (Get-Command Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue) {
            try {
                $im = Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop |
                    Where-Object { $_.DisplayName -match '(?i)interrupt.*moderation' } | Select-Object -First 1
                if ($im) {
                    $entry.InterruptModerationSupported=$true
                    $entry.InterruptModerationName=[string]$im.DisplayName
                    $entry.InterruptModerationValue=[string]$im.DisplayValue
                }
            } catch {}
        }
        if (Get-Command Get-NetAdapterRss -ErrorAction SilentlyContinue) {
            try {
                $rss = Get-NetAdapterRss -Name $adapter.Name -ErrorAction Stop
                $entry.RssSupported = $true
                $entry.RssEnabled = [bool]$rss.Enabled
            } catch {}
        }
        if (Get-Command Get-NetAdapterRsc -ErrorAction SilentlyContinue) {
            try {
                $rsc = Get-NetAdapterRsc -Name $adapter.Name -ErrorAction Stop
                $entry.RscSupported = $true
                $entry.RscIPv4 = [bool]$rsc.IPv4Enabled
                $entry.RscIPv6 = [bool]$rsc.IPv6Enabled
            } catch {}
        }
        $states += [pscustomobject]$entry
    }
    return $states
}

function Enable-LowLatencyAdapters {
    param([object[]]$State)
    # Lowest-latency NIC path: RSS stays enabled. RSC is disabled only for the game session.
    # Interrupt Moderation is disabled only when the driver exposes a matching advanced property.
    foreach ($entry in @($State)) {
        if ($entry.InterruptModerationSupported -and (Get-Command Set-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue)) {
            try {
                Set-NetAdapterAdvancedProperty -Name ([string]$entry.Name) -DisplayName ([string]$entry.InterruptModerationName) -DisplayValue 'Disabled' -NoRestart -ErrorAction Stop | Out-Null
            } catch {}
        }
        if ($entry.RssSupported -and (Get-Command Enable-NetAdapterRss -ErrorAction SilentlyContinue)) {
            try { Enable-NetAdapterRss -Name ([string]$entry.Name) -NoRestart -Confirm:$false -ErrorAction Stop | Out-Null } catch {}
        }
        if ($entry.RscSupported -and (Get-Command Disable-NetAdapterRsc -ErrorAction SilentlyContinue)) {
            # RSC trades latency for throughput. MAX profile disables it only on active adapters while FiveM is open.
            try { Disable-NetAdapterRsc -Name ([string]$entry.Name) -NoRestart -Confirm:$false -ErrorAction Stop | Out-Null } catch {}
        }
    }
}

function Restore-AdapterLatencyState {
    param([object[]]$State)
    foreach ($entry in @($State)) {
        if ($entry.InterruptModerationSupported -and $entry.InterruptModerationValue -and (Get-Command Set-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue)) {
            try {
                Set-NetAdapterAdvancedProperty -Name ([string]$entry.Name) -DisplayName ([string]$entry.InterruptModerationName) -DisplayValue ([string]$entry.InterruptModerationValue) -NoRestart -ErrorAction Stop | Out-Null
            } catch {}
        }
        if ($entry.RssSupported) {
            if ([bool]$entry.RssEnabled -and (Get-Command Enable-NetAdapterRss -ErrorAction SilentlyContinue)) {
                try { Enable-NetAdapterRss -Name ([string]$entry.Name) -NoRestart -Confirm:$false -ErrorAction Stop | Out-Null } catch {}
            } elseif (Get-Command Disable-NetAdapterRss -ErrorAction SilentlyContinue) {
                try { Disable-NetAdapterRss -Name ([string]$entry.Name) -NoRestart -Confirm:$false -ErrorAction Stop | Out-Null } catch {}
            }
        }
        if ($entry.RscSupported) {
            # Get-NetAdapterRsc exposes IPv4/IPv6 state, but the enable/disable cmdlets act per adapter.
            # If either stack was enabled before the game, re-enable RSC; otherwise keep it disabled.
            if (([bool]$entry.RscIPv4 -or [bool]$entry.RscIPv6) -and (Get-Command Enable-NetAdapterRsc -ErrorAction SilentlyContinue)) {
                try { Enable-NetAdapterRsc -Name ([string]$entry.Name) -NoRestart -Confirm:$false -ErrorAction Stop | Out-Null } catch {}
            } elseif (Get-Command Disable-NetAdapterRsc -ErrorAction SilentlyContinue) {
                try { Disable-NetAdapterRsc -Name ([string]$entry.Name) -NoRestart -Confirm:$false -ErrorAction Stop | Out-Null } catch {}
            }
        }
    }
}

function Set-FiveMGpuPreference([string]$Path) {
    if (-not $Path) { return }
    New-Item -Path $gpuKey -Force | Out-Null
    $entries = @()
    if (Test-Path -LiteralPath $gpuState) {
        try { $entries = @(Import-Clixml -LiteralPath $gpuState -ErrorAction Stop) } catch { $entries = @() }
    }
    $alreadySaved = @($entries | Where-Object { [string]::Equals([string]$_.Name, $Path, 'OrdinalIgnoreCase') }).Count -gt 0
    if (-not $alreadySaved) {
        $entries += Get-RegistryValueState -Path $gpuKey -Name $Path
        $entries | Export-Clixml -LiteralPath $gpuState -Force
    }
    New-ItemProperty -LiteralPath $gpuKey -Name $Path -Value 'GpuPreference=2;' `
        -PropertyType String -Force | Out-Null
}

function Register-InstalledFiveMExecutables {
    $fiveMRoot = Join-Path $env:LOCALAPPDATA 'FiveM'
    if (-not (Test-Path -LiteralPath $fiveMRoot)) { return }
    @(Get-ChildItem -LiteralPath $fiveMRoot -Filter 'FiveM*.exe' -File -Recurse -ErrorAction SilentlyContinue) |
        ForEach-Object { Set-FiveMGpuPreference -Path $_.FullName }
}

function Remove-SessionQos {
    if (-not (Get-Command Get-NetQosPolicy -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command Remove-NetQosPolicy -ErrorAction SilentlyContinue)) { return }
    @(Get-NetQosPolicy -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
        Where-Object Name -like ($qosPrefix + '*')) |
        ForEach-Object {
            Remove-NetQosPolicy -Name $_.Name -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
        }
}

function Start-GameSession {
    $previousPower = Get-ActivePowerGuid
    $registryState = @(
        Get-RegistryValueState -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR'
        Get-RegistryValueState -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled'
        Get-RegistryValueState -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled'
        Get-RegistryValueState -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled'
        Get-RegistryValueState -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AllowAutoGameMode'
        Get-RegistryValueState -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'NetworkThrottlingIndex'
        Get-RegistryValueState -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'SystemResponsiveness'
        Get-RegistryValueState -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' -Name 'GPU Priority'
        Get-RegistryValueState -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' -Name 'Priority'
        Get-RegistryValueState -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' -Name 'Scheduling Category'
        Get-RegistryValueState -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' -Name 'SFIO Priority'
        Get-RegistryValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name 'Win32PrioritySeparation'
    )
    $adapterState = Get-ActiveAdapterLatencyState
    [pscustomobject]@{
        StartedAt = Get-Date
        PreviousPower = $previousPower
        Paths = @()
        RegistryState = $registryState
        AdapterState = $adapterState
    } | Export-Clixml -LiteralPath $runtimeState -Force

    $profileGuid = if (Test-Path -LiteralPath $profileGuidFile) {
        [string](Get-Content -LiteralPath $profileGuidFile -Raw).Trim()
    } else { 'SCHEME_MIN' }
    & powercfg.exe /setactive $profileGuid 2>&1 | Out-Null
    Set-SessionGameSettings
    Enable-LowLatencyAdapters -State $adapterState
    $script:active = $true
    $script:missingCycles = 0
    Write-WatcherLog ('ENTER FiveM session; previous power=' + $previousPower)
}

function Boost-Process($Process) {
    $idKey = [string]$Process.Id
    if ($script:knownProcesses.ContainsKey($idKey)) { return }
    $priorityClass = if ($Process.ProcessName -like '*GTAProcess*') { 'High' } else { 'AboveNormal' }
    try { $Process.PriorityClass = $priorityClass } catch {}
    try { $Process.PriorityBoostEnabled = $true } catch {}
    $memoryPriority = $false
    $ecoQosOff = $false
    try { $memoryPriority = [FiveMProcessV4]::SetNormalMemoryPriority($Process.Handle) } catch {}
    try { $ecoQosOff = [FiveMProcessV4]::DisableExecutionSpeedThrottling($Process.Handle) } catch {}

    $path = $null
    try { $path = $Process.Path } catch {}
    if ($path) {
        $script:sessionPaths.Add($path) | Out-Null
        & powercfg.exe /powerthrottling disable /path $path 2>&1 | Out-Null
        Set-FiveMGpuPreference -Path $path
        $exeName = Split-Path -Leaf $path
        $safeName = ($exeName -replace '[^A-Za-z0-9_.-]', '_')
        $policyName = $qosPrefix + $safeName
        try {
            if (-not (Get-Command Get-NetQosPolicy -ErrorAction SilentlyContinue)) { throw 'QoS cmdlets unavailable' }
            if (-not (Get-Command New-NetQosPolicy -ErrorAction SilentlyContinue)) { throw 'QoS cmdlets unavailable' }
            if (-not (Get-Command Remove-NetQosPolicy -ErrorAction SilentlyContinue)) { throw 'QoS cmdlets unavailable' }
            Get-NetQosPolicy -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
                Where-Object Name -eq $policyName |
                Remove-NetQosPolicy -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
            New-NetQosPolicy -Name $policyName -AppPathNameMatchCondition $exeName `
                -IPProtocolMatchCondition Both -DSCPAction 46 -NetworkProfile All `
                -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }

    $script:knownProcesses[$idKey] = $true
    $state = $null
    if (Test-Path -LiteralPath $runtimeState) {
        try { $state = Import-Clixml -LiteralPath $runtimeState -ErrorAction Stop } catch { $state = $null }
    }
    if ($state) {
        $state.Paths = @($script:sessionPaths)
        $state | Export-Clixml -LiteralPath $runtimeState -Force
    }
    Write-WatcherLog ('HIY ARDUINO ' + $Process.ProcessName + ' PID=' + $Process.Id +
        ' priority=' + $priorityClass + ' memory5=' + $memoryPriority +
        ' highQosTimerHonor=' + $ecoQosOff)
}

function Stop-GameSession {
    $state = $null
    if (Test-Path -LiteralPath $runtimeState) {
        try { $state = Import-Clixml -LiteralPath $runtimeState -ErrorAction Stop } catch { $state = $null }
    }
    $pathsToReset = @($script:sessionPaths)
    if ($state) { $pathsToReset += @($state.Paths) }
    foreach ($path in @($pathsToReset | Where-Object { $_ } | Select-Object -Unique)) {
        & powercfg.exe /powerthrottling reset /path $path 2>&1 | Out-Null
    }
    Remove-SessionQos
    if ($state) {
        Restore-AdapterLatencyState -State @($state.AdapterState)
        foreach ($entry in @($state.RegistryState)) { Restore-RegistryValue -Entry $entry }
    }
    if ($state -and $state.PreviousPower) {
        & powercfg.exe /setactive ([string]$state.PreviousPower) 2>&1 | Out-Null
    }
    Remove-Item -LiteralPath $runtimeState -Force -ErrorAction SilentlyContinue
    $script:sessionPaths.Clear()
    $script:knownProcesses.Clear()
    $script:active = $false
    $script:missingCycles = 0
    Write-WatcherLog 'EXIT FiveM session; settings restored'
}

New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
Register-InstalledFiveMExecutables

# Recover safely if Windows shut down while a previous session was active.
if ((Test-Path -LiteralPath $runtimeState) -and (Get-FiveMProcesses).Count -eq 0) {
    Stop-GameSession
}

Write-WatcherLog 'Watcher started'
while ($true) {
    $processes = @(Get-FiveMProcesses)
    if ($processes.Count -gt 0) {
        if (-not $active) { Start-GameSession }
        $missingCycles = 0
        foreach ($process in $processes) { Boost-Process -Process $process }
        foreach ($idKey in @($knownProcesses.Keys)) {
            if (-not (Get-Process -Id ([int]$idKey) -ErrorAction SilentlyContinue)) {
                $knownProcesses.Remove($idKey)
            }
        }
    } elseif ($active) {
        $missingCycles++
        if ($missingCycles -ge 5) { Stop-GameSession }
    }
    Start-Sleep -Seconds 2
}
'@
}

function Invoke-ExternalCleanup {
    $state = $null
    if (Test-Path -LiteralPath $RuntimeState) {
        try { $state = Import-Clixml -LiteralPath $RuntimeState -ErrorAction Stop } catch { $state = $null }
    }
    if ($state) {
        # Restore adapter RSS/RSC state if a prior session crashed or Windows shut down mid-game.
        foreach ($entry in @($state.AdapterState)) {
            if (-not $entry) { continue }
            if ($entry.RssSupported) {
                if ([bool]$entry.RssEnabled -and (Get-Command Enable-NetAdapterRss -ErrorAction SilentlyContinue)) {
                    try { Enable-NetAdapterRss -Name ([string]$entry.Name) -NoRestart -Confirm:$false -ErrorAction Stop | Out-Null } catch {}
                } elseif (Get-Command Disable-NetAdapterRss -ErrorAction SilentlyContinue) {
                    try { Disable-NetAdapterRss -Name ([string]$entry.Name) -NoRestart -Confirm:$false -ErrorAction Stop | Out-Null } catch {}
                }
            }
            if ($entry.RscSupported) {
                if (([bool]$entry.RscIPv4 -or [bool]$entry.RscIPv6) -and (Get-Command Enable-NetAdapterRsc -ErrorAction SilentlyContinue)) {
                    try { Enable-NetAdapterRsc -Name ([string]$entry.Name) -NoRestart -Confirm:$false -ErrorAction Stop | Out-Null } catch {}
                } elseif (Get-Command Disable-NetAdapterRsc -ErrorAction SilentlyContinue) {
                    try { Disable-NetAdapterRsc -Name ([string]$entry.Name) -NoRestart -Confirm:$false -ErrorAction Stop | Out-Null } catch {}
                }
            }
        }
        foreach ($path in @($state.Paths | Where-Object { $_ } | Select-Object -Unique)) {
            & powercfg.exe /powerthrottling reset /path ([string]$path) 2>$null | Out-Null
        }
        if ($state.PreviousPower) {
            & powercfg.exe /setactive ([string]$state.PreviousPower) 2>$null | Out-Null
        }
        foreach ($entry in @($state.RegistryState)) {
            if (-not $entry) { continue }
            if ([bool]$entry.Exists) {
                New-Item -Path ([string]$entry.Path) -Force | Out-Null
                New-ItemProperty -LiteralPath ([string]$entry.Path) -Name ([string]$entry.Name) `
                    -Value $entry.Value -PropertyType ([string]$entry.Kind) -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath ([string]$entry.Path) -Name ([string]$entry.Name) `
                    -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ((Get-Command Get-NetQosPolicy -ErrorAction SilentlyContinue) -and
        (Get-Command Remove-NetQosPolicy -ErrorAction SilentlyContinue)) {
        @(Get-NetQosPolicy -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
            Where-Object Name -like ($QosPrefix + '*')) |
            ForEach-Object {
                Remove-NetQosPolicy -Name $_.Name -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
            }
    }
    Remove-Item -LiteralPath $RuntimeState -Force -ErrorAction SilentlyContinue
}

function Restore-GpuPreferences {
    if (-not (Test-Path -LiteralPath $GpuState)) { return }
    $gpuKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $gpuEntries = @()
    try { $gpuEntries = @(Import-Clixml -LiteralPath $GpuState -ErrorAction Stop) } catch { $gpuEntries = @() }
    foreach ($entry in $gpuEntries) {
        if (-not $entry) { continue }
        if ([bool]$entry.Exists) {
            New-Item -Path $gpuKey -Force | Out-Null
            New-ItemProperty -LiteralPath $gpuKey -Name ([string]$entry.Name) `
                -Value $entry.Value -PropertyType ([string]$entry.Kind) -Force | Out-Null
        } else {
            Remove-ItemProperty -LiteralPath $gpuKey -Name ([string]$entry.Name) `
                -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $GpuState -Force -ErrorAction SilentlyContinue
}

function Remove-PreviousV3Profile {
    $oldTaskName = 'FiveM Session V3 12400 RTX3070Ti'
    $oldTask = Get-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue
    if (-not $oldTask) { return }

    $oldDirectory = Join-Path $env:ProgramData 'FiveM-Session-V3-12400-3070Ti'
    $oldRuntime = Join-Path $oldDirectory 'runtime-state.clixml'
    $oldProfileGuid = Join-Path $oldDirectory 'profile-guid.txt'
    Stop-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300

    $oldState = $null
    if (Test-Path -LiteralPath $oldRuntime) {
        try { $oldState = Import-Clixml -LiteralPath $oldRuntime -ErrorAction Stop } catch { $oldState = $null }
    }
    if ($oldState) {
        foreach ($path in @($oldState.Paths | Where-Object { $_ } | Select-Object -Unique)) {
            & powercfg.exe /powerthrottling reset /path ([string]$path) 2>$null | Out-Null
        }
        if ($oldState.PreviousPower) {
            & powercfg.exe /setactive ([string]$oldState.PreviousPower) 2>$null | Out-Null
        }
    }
    if ((Get-Command Get-NetQosPolicy -ErrorAction SilentlyContinue) -and
        (Get-Command Remove-NetQosPolicy -ErrorAction SilentlyContinue)) {
        @(Get-NetQosPolicy -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
            Where-Object Name -like 'FiveM-SessionV3-*') |
            ForEach-Object {
                Remove-NetQosPolicy -Name $_.Name -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
            }
    }
    Unregister-ScheduledTask -TaskName $oldTaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $oldProfileGuid) {
        $oldGuid = [string](Get-Content -LiteralPath $oldProfileGuid -Raw).Trim()
        if ($oldGuid) { & powercfg.exe /delete $oldGuid 2>$null | Out-Null }
    }
    foreach ($oldFile in @('runtime-state.clixml','FiveM-Session-Watcher.ps1','watcher.log','profile-guid.txt')) {
        Remove-Item -LiteralPath (Join-Path $oldDirectory $oldFile) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $oldDirectory -ErrorAction SilentlyContinue
    Write-Host 'Previous V3 installed profile was migrated to V4.' -ForegroundColor DarkGray
}

function Remove-PreviousFixedV4Profile {
    $oldTaskName = 'FiveM Session V4 MAX 12400 RTX3070Ti'
    $oldTask = Get-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue
    if (-not $oldTask) { return }

    $oldDirectory = Join-Path $env:ProgramData 'FiveM-Session-V4-12400-3070Ti'
    $oldRuntime = Join-Path $oldDirectory 'runtime-state.clixml'
    $oldGpuState = Join-Path $oldDirectory 'gpu-preferences.clixml'
    $oldProfileGuid = Join-Path $oldDirectory 'profile-guid.txt'
    Stop-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300

    $oldState = $null
    if (Test-Path -LiteralPath $oldRuntime) {
        try { $oldState = Import-Clixml -LiteralPath $oldRuntime -ErrorAction Stop } catch { $oldState = $null }
    }
    if ($oldState) {
        foreach ($path in @($oldState.Paths | Where-Object { $_ } | Select-Object -Unique)) {
            & powercfg.exe /powerthrottling reset /path ([string]$path) 2>$null | Out-Null
        }
        if ($oldState.PreviousPower) {
            & powercfg.exe /setactive ([string]$oldState.PreviousPower) 2>$null | Out-Null
        }
        foreach ($entry in @($oldState.RegistryState)) {
            if (-not $entry) { continue }
            if ([bool]$entry.Exists) {
                New-Item -Path ([string]$entry.Path) -Force | Out-Null
                New-ItemProperty -LiteralPath ([string]$entry.Path) -Name ([string]$entry.Name) `
                    -Value $entry.Value -PropertyType ([string]$entry.Kind) -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath ([string]$entry.Path) -Name ([string]$entry.Name) `
                    -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ((Get-Command Get-NetQosPolicy -ErrorAction SilentlyContinue) -and
        (Get-Command Remove-NetQosPolicy -ErrorAction SilentlyContinue)) {
        @(Get-NetQosPolicy -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
            Where-Object Name -like 'FiveM-SessionV4-*') |
            ForEach-Object {
                Remove-NetQosPolicy -Name $_.Name -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
            }
    }
    if (Test-Path -LiteralPath $oldGpuState) {
        $gpuKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
        $oldGpuEntries = @()
        try { $oldGpuEntries = @(Import-Clixml -LiteralPath $oldGpuState -ErrorAction Stop) } catch { $oldGpuEntries = @() }
        foreach ($entry in $oldGpuEntries) {
            if (-not $entry) { continue }
            if ([bool]$entry.Exists) {
                New-Item -Path $gpuKey -Force | Out-Null
                New-ItemProperty -LiteralPath $gpuKey -Name ([string]$entry.Name) `
                    -Value $entry.Value -PropertyType ([string]$entry.Kind) -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $gpuKey -Name ([string]$entry.Name) `
                    -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Unregister-ScheduledTask -TaskName $oldTaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $oldProfileGuid) {
        $oldGuid = [string](Get-Content -LiteralPath $oldProfileGuid -Raw).Trim()
        if ($oldGuid) { & powercfg.exe /delete $oldGuid 2>$null | Out-Null }
    }
    foreach ($oldFile in @('runtime-state.clixml','gpu-preferences.clixml','FiveM-Session-Watcher.ps1','watcher.log','profile-guid.txt')) {
        Remove-Item -LiteralPath (Join-Path $oldDirectory $oldFile) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $oldDirectory -ErrorAction SilentlyContinue
    Write-Host 'Previous fixed-spec V4 profile was migrated to Universal.' -ForegroundColor DarkGray
}

function Invoke-PowerCfgSafe([string[]]$Arguments) {
    $savedPreference = $ErrorActionPreference
    $text = ''
    $exitCode = -1
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $rawOutput = @(& powercfg.exe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $text = ($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    } catch {
        $text = [string]$_.Exception.Message
        $exitCode = -1
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Remove-OrphanUniversalPowerPlans {
    $savedGuid = $null
    if (Test-Path -LiteralPath $ProfileGuidFile) {
        $savedGuid = [string](Get-Content -LiteralPath $ProfileGuidFile -Raw).Trim()
    }
    $activeText = (Invoke-PowerCfgSafe -Arguments @('/getactivescheme')).Text
    $activeMatch = [regex]::Match($activeText, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
    $activeGuid = if ($activeMatch.Success) { $activeMatch.Value } else { $null }
    $listText = (Invoke-PowerCfgSafe -Arguments @('/list')).Text
    $matches = [regex]::Matches(
        $listText,
        '(?im)^.*?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}).*?\((?:FiveM Session V4 Universal|Arduino V8 Adaptive MAX)\)\s*\*?\s*$'
    )
    foreach ($match in $matches) {
        $candidate = $match.Groups[1].Value
        if ([string]::Equals($candidate, $savedGuid, 'OrdinalIgnoreCase')) { continue }
        if ([string]::Equals($candidate, $activeGuid, 'OrdinalIgnoreCase')) { continue }
        [void](Invoke-PowerCfgSafe -Arguments @('/delete',$candidate))
    }
}

function Install-SessionPowerPlan {
    $existingGuid = if (Test-Path -LiteralPath $ProfileGuidFile) {
        [string](Get-Content -LiteralPath $ProfileGuidFile -Raw).Trim()
    } else { $null }
    $powerList = (Invoke-PowerCfgSafe -Arguments @('/list')).Text
    if ($existingGuid -and $powerList -match [regex]::Escape($existingGuid)) {
        [void](Invoke-PowerCfgSafe -Arguments @('/changename',$existingGuid,'Arduino V8 Adaptive MAX','High profile; active only while FiveM runs'))
        return $existingGuid
    }

    $activeOutput = (Invoke-PowerCfgSafe -Arguments @('/getactivescheme')).Text
    $activeMatch = [regex]::Match($activeOutput, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
    $sourceGuid = if ($activeMatch.Success) { $activeMatch.Value } else { 'SCHEME_BALANCED' }
    $duplicate = (Invoke-PowerCfgSafe -Arguments @('/duplicatescheme',$sourceGuid)).Text
    $match = [regex]::Match($duplicate, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
    if (-not $match.Success) {
        $duplicate = (Invoke-PowerCfgSafe -Arguments @('/duplicatescheme','SCHEME_BALANCED')).Text
        $match = [regex]::Match($duplicate, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
    }
    if (-not $match.Success) { throw 'Windows could not create an isolated FiveM power plan.' }
    $guid = $match.Value
    [void](Invoke-PowerCfgSafe -Arguments @('/changename',$guid,'Arduino V8 Adaptive MAX','High profile; active only while FiveM runs'))
    $powerSettings = @(
        @('54533251-82be-4824-96c1-47b60b740d00','893dee8e-2bef-41e0-89c6-b55d0929964c',5),
        @('54533251-82be-4824-96c1-47b60b740d00','bc5038f7-23e0-4960-96da-33abaf5935ec',100),
        @('54533251-82be-4824-96c1-47b60b740d00','0cc5b647-c1df-4637-891a-dec35c318583',100),
        @('54533251-82be-4824-96c1-47b60b740d00','36687f9e-e3a5-4dbf-b1dc-15eb381c6863',0),
        @('54533251-82be-4824-96c1-47b60b740d00','be337238-0d82-4146-a960-4f3749d470c7',2),
        @('501a4d13-42af-4429-9fd1-a8218c268e20','ee12f906-d277-404b-b6da-e5fa1a576df5',0),
        @('0012ee47-9041-4b5d-9b77-535fba8b1442','6738e2c4-e8a5-4a42-b16a-e040e769756e',0),
        @('2a737441-1930-4402-8d77-b2bebba308a3','48e6b7a6-50f5-4782-a5d4-53bb8f07e226',0)
    )
    foreach ($setting in $powerSettings) {
        $subgroup = [string]$setting[0]
        $settingName = [string]$setting[1]
        $settingValue = [string]$setting[2]
        $supported = Invoke-PowerCfgSafe -Arguments @('/qh',$guid,$subgroup)
        if ($supported.ExitCode -eq 0 -and $supported.Text -match [regex]::Escape($settingName)) {
            [void](Invoke-PowerCfgSafe -Arguments @('/setacvalueindex',$guid,$subgroup,$settingName,$settingValue))
        }
    }
    Set-Content -LiteralPath $ProfileGuidFile -Value $guid -Encoding ASCII -Force
    return $guid
}


function Install-ArduinoContextMenu {
    $base = 'HKCU:\Software\Classes\DesktopBackground\Shell\Arduino'
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $base -Force | Out-Null
    New-ItemProperty -Path $base -Name 'MUIVerb' -Value 'Arduino' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $base -Name 'Icon' -Value 'powershell.exe' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $base -Name 'Position' -Value 'Top' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $base -Name 'SubCommands' -Value '' -PropertyType String -Force | Out-Null

    $shell = Join-Path $base 'shell'
    New-Item -Path $shell -Force | Out-Null
    $items = @(
        @{Key='01_INSTALL'; Text='Install / Update V6 MAX'; Action='install'; Sep=$false},
        @{Key='02_START';   Text='Start MAX Watcher Now'; Action='start'; Sep=$false},
        @{Key='03_STATUS';  Text='Status / Current Settings'; Action='status'; Sep=$false},
        @{Key='04_REMOVE';  Text='Reset + Remove Everything'; Action='remove'; Sep=$true}
    )
    foreach($item in $items){
        $k = Join-Path $shell $item.Key
        New-Item -Path $k -Force | Out-Null
        New-ItemProperty -Path $k -Name 'MUIVerb' -Value $item.Text -PropertyType String -Force | Out-Null
        if($item.Sep){ New-ItemProperty -Path $k -Name 'CommandFlags' -Value 32 -PropertyType DWord -Force | Out-Null }
        $cmd = Join-Path $k 'command'
        New-Item -Path $cmd -Force | Out-Null
        # Launch the installed BAT explicitly through cmd.exe.
        # This avoids relying on the Windows .bat file association.
        $escapedSelf = $SelfPath.Replace('"','""')
        $commandLine = ('"{0}" /d /s /c ""{1}" {2}"' -f $env:ComSpec,$escapedSelf,$item.Action)
        Set-Item -LiteralPath $cmd -Value $commandLine -Force
    }
}

function Remove-ArduinoContextMenu {
    Remove-Item -LiteralPath 'HKCU:\Software\Classes\DesktopBackground\Shell\Arduino' -Recurse -Force -ErrorAction SilentlyContinue
}

function Install-SessionProfile {
    Write-Title
    if (-not (Request-Administrator -RequestedAction 'install')) { return }
    Remove-Item -LiteralPath $ErrorLog -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    Invoke-ExternalCleanup
    Remove-PreviousFixedV4Profile
    Remove-PreviousV3Profile
    Remove-OrphanUniversalPowerPlans
    $profileGuid = Install-SessionPowerPlan
    Set-Content -LiteralPath $WatcherPath -Value (Get-WatcherSource) -Encoding UTF8 -Force

    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $WatcherPath
    $taskAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments
    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $taskTrigger `
        -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Install-ArduinoContextMenu

    Write-Host '   READY' -ForegroundColor Green
    Write-Host ('Session power plan: {0}' -f $profileGuid)
    Write-Host 'HIY ARDUINO: GTA process High; CitizenFX helpers Above normal.'
    Write-Host 'MAX: GPEDIT Game DVR off + MMCSS Games High + Win32 foreground scheduling.'
    Write-Host 'Internet: active-adapter RSS ON + RSC OFF during FiveM; exact state restored on exit.'
    Write-Host 'Process: HighQoS/timer honoring, memory priority 5, DSCP 46, Game Mode, GPU preference.'
    Write-Host 'From now on: open FiveM normally. Boost and session restore are automatic.'
    Write-Host 'The GPU preference is FiveM-only and is restored by option 4.'
    Write-Host 'Desktop right-click menu: Arduino installed.'
    Write-Host 'No restart is required.'
    Write-Host
    Read-Host '   Enter to close'
}

function Start-WatcherNow {
    Write-Title
    if (-not (Request-Administrator -RequestedAction 'start')) { return }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host 'HIY ARDUINO V6 MAX is not installed. Choose option 1 first.' -ForegroundColor Yellow
    } else {
        Start-ScheduledTask -TaskName $TaskName
        Write-Host '   ADAPTIVE MAX ACTIVE' -ForegroundColor Green
    }
    Read-Host '   Enter to close'
}

function Show-Status {
    Write-Title
    if (-not (Request-Administrator -RequestedAction 'status')) { return }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host ('Installed: {0}' -f [bool]$task)
    if ($task) { Write-Host ('Watcher task: {0}' -f $task.State) }
    Write-Host ('FiveM running: {0}' -f (@(Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -like 'FiveM*').Count -gt 0))
    Write-Host ('Session active: {0}' -f (Test-Path -LiteralPath $RuntimeState))
    Write-Host ((& powercfg.exe /getactivescheme 2>$null | Out-String).Trim())
    if (Test-Path -LiteralPath $WatcherLog) {
        Write-Host
        Write-Host 'Recent activity:' -ForegroundColor Cyan
        Get-Content -LiteralPath $WatcherLog -Tail 12
    }
    Write-Host
    Read-Host '   Enter to close'
}

function Remove-SessionProfile {
    Write-Title
    if (-not (Request-Administrator -RequestedAction 'remove')) { return }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Invoke-ExternalCleanup
    Restore-GpuPreferences
    Remove-ArduinoContextMenu
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $profileGuid = if (Test-Path -LiteralPath $ProfileGuidFile) {
        [string](Get-Content -LiteralPath $ProfileGuidFile -Raw).Trim()
    } else { $null }
    if ($profileGuid) { & powercfg.exe /delete $profileGuid 2>$null | Out-Null }
    Remove-Item -LiteralPath $WatcherPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $WatcherLog -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ProfileGuidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $GpuState -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $DataDirectory) {
        Remove-Item -LiteralPath $DataDirectory -ErrorAction SilentlyContinue
    }
    Write-Host '   RESET COMPLETE' -ForegroundColor Green
    Write-Host
    Read-Host '   Enter to close'
}

function Show-Menu {
    Write-Title
    Write-Host '   [1] Install / Update' -ForegroundColor White
    Write-Host '   [2] Start Adaptive MAX' -ForegroundColor White
    Write-Host '   [3] Status' -ForegroundColor White
    Write-Host '   [4] Reset / Remove' -ForegroundColor White
    Write-Host '   [5] Exit' -ForegroundColor DarkGray
    Write-Host
    $choice = Read-Host '   Select'
    switch ($choice) {
        '1' { Install-SessionProfile }
        '2' { Start-WatcherNow }
        '3' { Show-Status }
        '4' { Remove-SessionProfile }
        default { return }
    }
}

switch ($Action.ToLowerInvariant()) {
    'install'  { Install-SessionProfile }
    'start'    { Start-WatcherNow }
    'status'   { Show-Status }
    'remove'   { Remove-SessionProfile }
    'context'  { if (Request-Administrator -RequestedAction 'context') { Install-ArduinoContextMenu; Write-Host 'Arduino desktop menu installed.' -ForegroundColor Green; Start-Sleep 1 } }
    'selftest' {
        $watcherSource = Get-WatcherSource
        [scriptblock]::Create($watcherSource) | Out-Null
        $nativeMatch = [regex]::Match($watcherSource, 'Add-Type -TypeDefinition @"\r?\n(?<Code>[\s\S]*?)\r?\n"@')
        if (-not $nativeMatch.Success) { throw 'Embedded Win32 source was not found.' }
        Add-Type -TypeDefinition $nativeMatch.Groups['Code'].Value -ErrorAction Stop
        $selfProcess = [Diagnostics.Process]::GetCurrentProcess()
        [void][FiveMProcessV4]::SetNormalMemoryPriority($selfProcess.Handle)
        [void][FiveMProcessV4]::DisableExecutionSpeedThrottling($selfProcess.Handle)
        Write-Host 'HIY ARDUINO FiveM V6 MAX deep self-test: OK'
    }
    'firstinstalltest' {
        $RuntimeState = Join-Path $env:TEMP ('FiveM-V4-missing-' + [guid]::NewGuid().ToString('N') + '.clixml')
        $QosPrefix = 'FiveM-V4-SelfTest-Nonexistent-'
        Invoke-ExternalCleanup
        Write-Host 'HIY ARDUINO FiveM V6 MAX first-install cleanup test: OK'
    }
    'powercfgtest' {
        $activeResult = Invoke-PowerCfgSafe -Arguments @('/getactivescheme')
        $activeMatch = [regex]::Match($activeResult.Text, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
        if ($activeResult.ExitCode -ne 0 -or -not $activeMatch.Success) {
            throw 'Could not read the active Windows power plan.'
        }
        $queryResult = Invoke-PowerCfgSafe -Arguments @(
            '/qh',$activeMatch.Value,'54533251-82be-4824-96c1-47b60b740d00'
        )
        if ($queryResult.ExitCode -ne 0 -or
            $queryResult.Text -notmatch 'bc5038f7-23e0-4960-96da-33abaf5935ec') {
            throw 'Standard processor power setting is unavailable.'
        }
        Write-Host 'HIY ARDUINO FiveM V6 MAX powercfg compatibility test: OK'
    }
    default    { Show-Menu }
}
'@

$realtekSource = @'
$ErrorActionPreference = 'Stop'
$Action = $env:FIVEM_V2_ACTION
if ($null -eq $Action) { $Action = '' }
$SelfPath = $env:FIVEM_V2_SELF
$DataDirectory = Join-Path $env:ProgramData 'FiveM-12100-GTX1650-RealtekGbE'
$StateFile = Join-Path $DataDirectory 'original-state.clixml'
$SessionLog = Join-Path $DataDirectory 'session-processes.txt'
$AutoBoostPathLog = Join-Path $DataDirectory 'autoboost-paths.txt'
$WatcherScript = Join-Path $DataDirectory 'FiveM-AutoBoost.ps1'
$AutoBoostTaskName = 'FiveM 12100 GTX1650 RealtekGbE AutoBoost'
$V1StateFile = Join-Path $env:ProgramData 'FiveM-LowLatency-Safe\original-state.clixml'
$ErrorLog = Join-Path $env:TEMP 'FiveM_12100_Realtek_Last_Error.log'
$QosPrefix = 'FiveM-12100-'
$TargetAdvancedKeywords = @(
    '*InterruptModeration',
    '*EEE',
    '*FlowControl',
    'EEELinkAdvertisement',
    'AdvancedEEE',
    'GreenEthernet',
    'PowerSavingMode',
    'AutoDisableGigabit',
    'GigabitLite'
)

trap {
    $record = $_
    $details = @(
        'FiveM i3-12100 Realtek tailored profile - unhandled error'
        ('Time: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        ('Action: {0}' -f $Action)
        ('Message: {0}' -f $record.Exception.Message)
        ('Category: {0}' -f $record.CategoryInfo)
        ('Position: {0}' -f $record.InvocationInfo.PositionMessage)
        ''
        'Full error:'
        ($record | Format-List * -Force | Out-String)
    ) -join [Environment]::NewLine
    try { Set-Content -LiteralPath $ErrorLog -Value $details -Encoding UTF8 -Force } catch {}
    Write-Host
    Write-Host 'REALTEK PROFILE STOPPED ON AN ERROR' -ForegroundColor Red
    Write-Host ('Message: {0}' -f $record.Exception.Message) -ForegroundColor Red
    Write-Host ('Error log: {0}' -f $ErrorLog) -ForegroundColor Yellow
    exit 1
}

function Write-Title {
    Clear-Host
    Write-Host '================================================================' -ForegroundColor Magenta
    Write-Host ' FiveM i3-12100 / GTX 1650 / REALTEK GBE PROFILE' -ForegroundColor Magenta
    Write-Host '================================================================' -ForegroundColor Magenta
    Write-Host 'Maximum legitimate responsiveness profile for wired desktop PCs.'
    Write-Host 'Higher CPU use, power draw and temperature are expected.' -ForegroundColor Yellow
    Write-Host 'This does not alter FiveM attack speed or manipulate packets.' -ForegroundColor Yellow
    Write-Host
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Administrator([string]$RequestedAction) {
    if (Test-Administrator) { return $true }
    Write-Host 'Requesting Administrator permission...' -ForegroundColor Yellow
    $cmdArguments = '/d /c ""{0}" {1}"' -f $SelfPath, $RequestedAction
    try {
        Start-Process -FilePath $env:ComSpec -Verb RunAs -ArgumentList $cmdArguments | Out-Null
    } catch {
        Write-Host 'Administrator permission was not granted.' -ForegroundColor Red
        Read-Host 'Press Enter to close'
    }
    return $false
}

function Get-RegistryValueState([string]$Path, [string]$Name) {
    try {
        $value = Get-ItemPropertyValue -LiteralPath $Path -Name $Name -ErrorAction Stop
        return [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $true; Value = $value }
    } catch {
        return [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $false; Value = $null }
    }
}

function Restore-RegistryValue($SavedValue) {
    if ($SavedValue.Exists) {
        New-Item -Path $SavedValue.Path -Force | Out-Null
        Set-ItemProperty -LiteralPath $SavedValue.Path -Name $SavedValue.Name -Value $SavedValue.Value -Force
    } elseif (Test-Path -LiteralPath $SavedValue.Path) {
        Remove-ItemProperty -LiteralPath $SavedValue.Path -Name $SavedValue.Name -ErrorAction SilentlyContinue
    }
}

function Get-ActiveEthernetAdapters {
    $physical = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up')
    return @($physical | Where-Object {
        $_.MediaType -eq '802.3' -or $_.PhysicalMediaType -eq '802.3'
    })
}

function Get-AdapterPowerState([string]$AdapterName) {
    try {
        $power = Get-NetAdapterPowerManagement -Name $AdapterName -ErrorAction Stop
        return [pscustomobject]@{
            Supported = $true
            SelectiveSuspend = [string]$power.SelectiveSuspend
            D0PacketCoalescing = [string]$power.D0PacketCoalescing
            DeviceSleepOnDisconnect = [string]$power.DeviceSleepOnDisconnect
        }
    } catch {
        return [pscustomobject]@{ Supported = $false }
    }
}

function Get-AdapterRscState([string]$AdapterName) {
    try {
        $rsc = Get-NetAdapterRsc -Name $AdapterName -ErrorAction Stop
        return [pscustomobject]@{
            Supported = $true
            IPv4Enabled = [bool]$rsc.IPv4Enabled
            IPv6Enabled = [bool]$rsc.IPv6Enabled
        }
    } catch {
        return [pscustomobject]@{ Supported = $false }
    }
}

function Get-AdapterUsoState([string]$AdapterName) {
    if (-not (Get-Command Get-NetAdapterUso -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Supported = $false }
    }
    try {
        $uso = Get-NetAdapterUso -Name $AdapterName -ErrorAction Stop
        return [pscustomobject]@{
            Supported = $true
            IPv4Enabled = [bool]$uso.IPv4Enabled
            IPv6Enabled = [bool]$uso.IPv6Enabled
        }
    } catch {
        return [pscustomobject]@{ Supported = $false }
    }
}

function New-OriginalState($Adapters) {
    $powerOutput = (& powercfg.exe /getactivescheme 2>&1 | Out-String)
    $guidMatch = [regex]::Match($powerOutput, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
    $globalOffload = $null
    try { $globalOffload = Get-NetOffloadGlobalSetting -ErrorAction Stop } catch {}

    $adapterStates = foreach ($adapter in $Adapters) {
        $advanced = @()
        try {
            $advanced = @(Get-NetAdapterAdvancedProperty -Name $adapter.Name -AllProperties -ErrorAction Stop |
                Where-Object { $TargetAdvancedKeywords -contains $_.RegistryKeyword } |
                ForEach-Object {
                    [pscustomobject]@{
                        RegistryKeyword = $_.RegistryKeyword
                        RegistryValue = @($_.RegistryValue)
                    }
                })
        } catch {}
        $rss = $null
        try { $rss = Get-NetAdapterRss -Name $adapter.Name -ErrorAction Stop } catch {}

        [pscustomobject]@{
            Name = $adapter.Name
            InterfaceDescription = $adapter.InterfaceDescription
            Advanced = $advanced
            RssSupported = ($null -ne $rss)
            RssEnabled = if ($null -ne $rss) { [bool]$rss.Enabled } else { $false }
            Rsc = Get-AdapterRscState -AdapterName $adapter.Name
            Uso = Get-AdapterUsoState -AdapterName $adapter.Name
            Power = Get-AdapterPowerState -AdapterName $adapter.Name
        }
    }

    $gameConfigPath = 'HKCU:\System\GameConfigStore'
    $gameDvrPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
    $gameBarPath = 'HKCU:\Software\Microsoft\GameBar'
    $mousePath = 'HKCU:\Control Panel\Mouse'
    return [pscustomobject]@{
        Version = 2
        CapturedAt = Get-Date
        ActivePowerScheme = if ($guidMatch.Success) { $guidMatch.Value } else { $null }
        AggressivePowerScheme = $null
        GlobalRss = if ($null -ne $globalOffload) { [string]$globalOffload.ReceiveSideScaling } else { $null }
        GlobalRsc = if ($null -ne $globalOffload) { [string]$globalOffload.ReceiveSegmentCoalescing } else { $null }
        GlobalPacketCoalescing = if ($null -ne $globalOffload) { [string]$globalOffload.PacketCoalescingFilter } else { $null }
        Registry = @(
            Get-RegistryValueState -Path $gameConfigPath -Name 'GameDVR_Enabled'
            Get-RegistryValueState -Path $gameDvrPath -Name 'AppCaptureEnabled'
            Get-RegistryValueState -Path $gameBarPath -Name 'AutoGameModeEnabled'
            Get-RegistryValueState -Path $gameBarPath -Name 'AllowAutoGameMode'
            Get-RegistryValueState -Path $mousePath -Name 'MouseSpeed'
            Get-RegistryValueState -Path $mousePath -Name 'MouseThreshold1'
            Get-RegistryValueState -Path $mousePath -Name 'MouseThreshold2'
        )
        PowerThrottlePaths = @()
        Adapters = @($adapterStates)
    }
}

function Invoke-PowerCfg([string[]]$Arguments) {
    & powercfg.exe @Arguments 2>&1 | Out-Null
}

function Set-AggressivePowerPlan {
    $state = Import-Clixml -LiteralPath $StateFile
    $schemeGuid = [string]$state.AggressivePowerScheme
    $schemeExists = $false
    if ($schemeGuid) {
        $list = (& powercfg.exe /list 2>&1 | Out-String)
        $schemeExists = $list -match [regex]::Escape($schemeGuid)
    }
    if (-not $schemeExists) {
        $duplicateOutput = (& powercfg.exe /duplicatescheme SCHEME_MIN 2>&1 | Out-String)
        $match = [regex]::Match($duplicateOutput, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
        if ($match.Success) {
            $schemeGuid = $match.Value
            $state.AggressivePowerScheme = $schemeGuid
            $state | Export-Clixml -LiteralPath $StateFile -Force
            Invoke-PowerCfg @('/changename', $schemeGuid, 'FiveM 12100 GTX1650 Realtek', 'Tailored AC-only gaming profile')
        }
    }
    if (-not $schemeGuid) {
        Write-Host 'Custom plan creation failed; using standard High Performance.' -ForegroundColor DarkYellow
        Invoke-PowerCfg @('/setactive', 'SCHEME_MIN')
        return
    }

    Invoke-PowerCfg @('/setacvalueindex', $schemeGuid, 'SUB_PROCESSOR', 'PROCTHROTTLEMIN', '100')
    Invoke-PowerCfg @('/setacvalueindex', $schemeGuid, 'SUB_PROCESSOR', 'PROCTHROTTLEMAX', '100')
    Invoke-PowerCfg @('/setacvalueindex', $schemeGuid, 'SUB_PROCESSOR', 'CPMINCORES', '100')
    Invoke-PowerCfg @('/setacvalueindex', $schemeGuid, 'SUB_PROCESSOR', 'CPMINCORES1', '100')
    Invoke-PowerCfg @('/setacvalueindex', $schemeGuid, 'SUB_PROCESSOR', 'PERFEPP', '0')
    Invoke-PowerCfg @('/setacvalueindex', $schemeGuid, 'SUB_PROCESSOR', 'PERFEPP1', '0')
    Invoke-PowerCfg @('/setacvalueindex', $schemeGuid, 'SUB_PROCESSOR', 'PERFBOOSTMODE', '2')
    Invoke-PowerCfg @('/setacvalueindex', $schemeGuid, 'SUB_PROCESSOR', 'SYSCOOLPOL', '0')
    Invoke-PowerCfg @('/setacvalueindex', $schemeGuid, 'SUB_PCIEXPRESS', 'ASPM', '0')
    Invoke-PowerCfg @('/setactive', $schemeGuid)
    Write-Host ('Power plan -> FiveM 12100 GTX1650 Realtek ({0})' -f $schemeGuid) -ForegroundColor Green
}

function Set-AdapterPowerFeature([string]$AdapterName, [string]$Feature, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'Unsupported') { return $false }
    try {
        $parameters = @{ Name = $AdapterName; NoRestart = $true; ErrorAction = 'Stop' }
        $parameters[$Feature] = $Value
        Set-NetAdapterPowerManagement @parameters | Out-Null
        return $true
    } catch {
        Write-Host ('  Power {0}: skipped' -f $Feature) -ForegroundColor DarkYellow
        return $false
    }
}

function Set-MouseAcceleration([int]$Threshold1, [int]$Threshold2, [int]$Acceleration) {
    try {
        if (-not ('FiveMV2.NativeMouse' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace FiveMV2 {
    public static class NativeMouse {
        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool SystemParametersInfo(uint action, uint param, int[] values, uint flags);
    }
}
'@
        }
        $values = [int[]]@($Threshold1, $Threshold2, $Acceleration)
        [FiveMV2.NativeMouse]::SystemParametersInfo(0x0004, 0, $values, 0x0003) | Out-Null
    } catch {
        Write-Host 'Mouse live refresh was blocked; the registry setting will apply after restart.' -ForegroundColor DarkYellow
    }
}

function Set-AggressiveRegistry {
    New-Item -Path 'HKCU:\System\GameConfigStore' -Force | Out-Null
    New-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -PropertyType DWord -Value 0 -Force | Out-Null
    New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Force | Out-Null
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -PropertyType DWord -Value 0 -Force | Out-Null
    New-Item -Path 'HKCU:\Software\Microsoft\GameBar' -Force | Out-Null
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AllowAutoGameMode' -PropertyType DWord -Value 1 -Force | Out-Null
    New-Item -Path 'HKCU:\Control Panel\Mouse' -Force | Out-Null
    New-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -PropertyType String -Value '0' -Force | Out-Null
    New-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold1' -PropertyType String -Value '0' -Force | Out-Null
    New-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold2' -PropertyType String -Value '0' -Force | Out-Null
    Set-MouseAcceleration -Threshold1 0 -Threshold2 0 -Acceleration 0
    Write-Host 'Game Mode -> On; Game capture -> Off; Mouse acceleration -> Off' -ForegroundColor Green
}

function Apply-AdapterTuning($Adapter) {
    Write-Host
    Write-Host ('Tuning adapter: {0} ({1})' -f $Adapter.Name, $Adapter.LinkSpeed) -ForegroundColor Cyan
    $restartNeeded = $false
    $properties = @()
    try {
        $properties = @(Get-NetAdapterAdvancedProperty -Name $Adapter.Name -AllProperties -ErrorAction Stop |
            Where-Object { $TargetAdvancedKeywords -contains $_.RegistryKeyword })
    } catch {}
    foreach ($property in $properties) {
        try {
            Set-NetAdapterAdvancedProperty -Name $Adapter.Name -RegistryKeyword $property.RegistryKeyword `
                -RegistryValue 0 -NoRestart -ErrorAction Stop | Out-Null
            Write-Host ('  {0} -> Disabled' -f $property.RegistryKeyword) -ForegroundColor Green
            $restartNeeded = $true
        } catch {
            Write-Host ('  {0}: skipped' -f $property.RegistryKeyword) -ForegroundColor DarkYellow
        }
    }
    try {
        Set-NetAdapterRss -Name $Adapter.Name -Enabled $true -NoRestart -ErrorAction Stop | Out-Null
        Write-Host '  RSS -> Enabled' -ForegroundColor Green
        $restartNeeded = $true
    } catch { Write-Host '  RSS: unsupported' -ForegroundColor DarkYellow }
    try {
        Set-NetAdapterRsc -Name $Adapter.Name -IPv4Enabled $false -IPv6Enabled $false -NoRestart -ErrorAction Stop | Out-Null
        Write-Host '  RSC -> Disabled (latency bias)' -ForegroundColor Green
        $restartNeeded = $true
    } catch { Write-Host '  RSC: unsupported' -ForegroundColor DarkYellow }
    if (Get-Command Set-NetAdapterUso -ErrorAction SilentlyContinue) {
        try {
            Set-NetAdapterUso -Name $Adapter.Name -IPv4Enabled $false -IPv6Enabled $false -NoRestart -ErrorAction Stop | Out-Null
            Write-Host '  UDP segmentation offload -> Disabled' -ForegroundColor Green
            $restartNeeded = $true
        } catch { Write-Host '  UDP segmentation offload: unsupported' -ForegroundColor DarkYellow }
    }
    $power = Get-AdapterPowerState -AdapterName $Adapter.Name
    if ($power.Supported) {
        if (Set-AdapterPowerFeature -AdapterName $Adapter.Name -Feature 'SelectiveSuspend' -Value 'Disabled') { $restartNeeded = $true }
        if (Set-AdapterPowerFeature -AdapterName $Adapter.Name -Feature 'D0PacketCoalescing' -Value 'Disabled') { $restartNeeded = $true }
        if (Set-AdapterPowerFeature -AdapterName $Adapter.Name -Feature 'DeviceSleepOnDisconnect' -Value 'Disabled') { $restartNeeded = $true }
    }
    if ($restartNeeded) {
        Write-Host '  Restarting adapter; network may drop briefly...' -ForegroundColor Yellow
        try { Restart-NetAdapter -Name $Adapter.Name -Confirm:$false -ErrorAction Stop } catch {
            Write-Host '  Restart failed; reboot Windows before testing.' -ForegroundColor DarkYellow
        }
    }
}

function Apply-Tuning {
    Write-Title
    if (-not (Request-Administrator -RequestedAction 'apply')) { return }
    Remove-Item -LiteralPath $ErrorLog -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    try {
        $adapters = @(Get-ActiveEthernetAdapters)
    } catch {
        $adapters = @()
        Write-Host ('Windows blocked the NIC query; NIC-specific tuning will be skipped: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
    }

    if (-not (Test-Path -LiteralPath $StateFile)) {
        if (Test-Path -LiteralPath $V1StateFile) {
            Write-Host 'V1 appears to be active. V2 will use the current V1-tuned state as its restore point.' -ForegroundColor Yellow
            Write-Host 'For a clean V2 baseline, close this window and restore V1 first.' -ForegroundColor Yellow
            Write-Host
        }
        Write-Host 'Saving original i3-12100 Realtek profile baseline...'
        New-OriginalState -Adapters $adapters | Export-Clixml -LiteralPath $StateFile -Force
        Write-Host ('Backup: {0}' -f $StateFile) -ForegroundColor DarkGray
    } else {
        Write-Host 'Using existing i3-12100 Realtek profile backup.' -ForegroundColor DarkGray
    }

    try {
        Set-AggressivePowerPlan
    } catch {
        Write-Host ('Custom power plan failed; continuing: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
    try {
        Set-AggressiveRegistry
    } catch {
        Write-Host ('Some Game Mode/input settings were blocked; continuing: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
    try {
        Set-NetOffloadGlobalSetting -ReceiveSideScaling Enabled -ReceiveSegmentCoalescing Disabled `
            -PacketCoalescingFilter Disabled -ErrorAction Stop | Out-Null
        Write-Host 'Global RSS -> On; RSC/packet coalescing -> Off' -ForegroundColor Green
    } catch {
        Write-Host 'Some global offload settings were unsupported.' -ForegroundColor DarkYellow
    }

    if ($adapters.Count -eq 0) {
        Write-Host 'No active wired Ethernet adapter found; NIC tuning was skipped.' -ForegroundColor Yellow
        Write-Host 'This profile is intended for the Realtek LAN cable, not Wi-Fi.' -ForegroundColor Yellow
    } else {
        foreach ($adapter in $adapters) { Apply-AdapterTuning -Adapter $adapter }
    }

    try {
        Install-PersistentAutoBoost
    } catch {
        Write-Host ('Persistent AutoBoost installation failed; manual option 2 still works: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
    }

    Write-Host
    Write-Host 'REALTEK PROFILE APPLIED.' -ForegroundColor Green
    Write-Host 'Restart Windows once. AutoBoost will activate whenever FiveM starts.'
    Write-Host 'Manual option 2 remains available as a fallback.'
    Write-Host 'If throughput, voice, stability or temperatures get worse, use option 4 Restore.' -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
}

function Add-SessionPathToState([string]$Path) {
    if (-not (Test-Path -LiteralPath $StateFile)) { return }
    $state = Import-Clixml -LiteralPath $StateFile
    $paths = @($state.PowerThrottlePaths)
    if ($paths -notcontains $Path) {
        $state.PowerThrottlePaths = @($paths + $Path)
        $state | Export-Clixml -LiteralPath $StateFile -Force
    }
}

function Install-PersistentAutoBoost {
    $watcherCode = @'
$ErrorActionPreference = 'SilentlyContinue'
$dataDirectory = Join-Path $env:ProgramData 'FiveM-12100-GTX1650-RealtekGbE'
$pathLog = Join-Path $dataDirectory 'autoboost-paths.txt'
$qosPrefix = 'FiveM-12100-Auto-'
$known = @{}
New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null

while ($true) {
    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -like 'FiveM*')
    foreach ($process in $processes) {
        $processId = [string]$process.Id
        if (-not $known.ContainsKey($processId)) {
            $priority = if ($process.ProcessName -like '*GTAProcess*') { 'High' } else { 'AboveNormal' }
            try { $process.PriorityClass = $priority } catch {}
            try {
                $path = $process.Path
                if ($path) {
                    & powercfg.exe /powerthrottling disable /path $path 2>&1 | Out-Null
                    $oldPaths = if (Test-Path -LiteralPath $pathLog) { @(Get-Content -LiteralPath $pathLog) } else { @() }
                    if ($oldPaths -notcontains $path) { Add-Content -LiteralPath $pathLog -Value $path }
                    $exeName = Split-Path -Leaf $path
                    $safeName = ($exeName -replace '[^A-Za-z0-9_.-]', '_')
                    $policyName = $qosPrefix + $safeName
                    Get-NetQosPolicy -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
                        Where-Object Name -eq $policyName |
                        Remove-NetQosPolicy -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
                    New-NetQosPolicy -Name $policyName -AppPathNameMatchCondition $exeName `
                        -IPProtocolMatchCondition UDP -DSCPAction 46 -NetworkProfile All `
                        -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Out-Null
                }
            } catch {}
            $known[$processId] = $true
        }
    }
    foreach ($processId in @($known.Keys)) {
        if (-not (Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue)) {
            $known.Remove($processId)
        }
    }
    Start-Sleep -Seconds 4
}
'@
    Set-Content -LiteralPath $WatcherScript -Value $watcherCode -Encoding UTF8 -Force

    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $WatcherScript
    $taskAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments
    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $AutoBoostTaskName -Action $taskAction -Trigger $taskTrigger `
        -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
    Start-ScheduledTask -TaskName $AutoBoostTaskName
    Write-Host 'Persistent AutoBoost -> Installed and running' -ForegroundColor Green
}

function Remove-PersistentAutoBoost {
    try { Stop-ScheduledTask -TaskName $AutoBoostTaskName -ErrorAction SilentlyContinue } catch {}
    try { Unregister-ScheduledTask -TaskName $AutoBoostTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    if (Test-Path -LiteralPath $AutoBoostPathLog) {
        foreach ($path in @(Get-Content -LiteralPath $AutoBoostPathLog -ErrorAction SilentlyContinue | Select-Object -Unique)) {
            if ($path) { Invoke-PowerCfg @('/powerthrottling', 'reset', '/path', [string]$path) }
        }
    }
    foreach ($policy in @(Get-NetQosPolicy -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
        Where-Object Name -like 'FiveM-12100-Auto-*')) {
        Remove-NetQosPolicy -Name $policy.Name -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $WatcherScript -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $AutoBoostPathLog -Force -ErrorAction SilentlyContinue
}

function Start-SessionBoost {
    Write-Title
    if (-not (Request-Administrator -RequestedAction 'session')) { return }
    if (-not (Test-Path -LiteralPath $StateFile)) {
        Write-Host 'Apply option 1 before using Session Boost so every persistent change can be restored.' -ForegroundColor Yellow
        Read-Host 'Press Enter to close'
        return
    }
    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -like 'FiveM*')
    if ($processes.Count -eq 0) {
        Write-Host 'FiveM is not running. Start FiveM first, then choose option 2.' -ForegroundColor Yellow
        Read-Host 'Press Enter to close'
        return
    }
    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    $sessionLines = @()
    foreach ($process in $processes) {
        try {
            $priority = if ($process.ProcessName -like '*GTAProcess*') { 'High' } else { 'AboveNormal' }
            $process.PriorityClass = $priority
            Write-Host ('  {0} (PID {1}) -> {2}' -f $process.ProcessName, $process.Id, $priority) -ForegroundColor Green
            $path = $process.Path
            if ($path) {
                Invoke-PowerCfg @('/powerthrottling', 'disable', '/path', $path)
                Add-SessionPathToState -Path $path
                $exeName = Split-Path -Leaf $path
                $safeName = ($exeName -replace '[^A-Za-z0-9_.-]', '_')
                $policyName = $QosPrefix + $safeName
                try {
                    Get-NetQosPolicy -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
                        Where-Object Name -eq $policyName |
                        Remove-NetQosPolicy -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
                    New-NetQosPolicy -Name $policyName -AppPathNameMatchCondition $exeName `
                        -IPProtocolMatchCondition UDP -DSCPAction 46 -NetworkProfile All `
                        -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
                    Write-Host ('    UDP DSCP 46 session policy -> {0}' -f $exeName) -ForegroundColor DarkGreen
                } catch {
                    Write-Host '    QoS marking unsupported; skipped.' -ForegroundColor DarkYellow
                }
                $sessionLines += ('{0}`t{1}`t{2}' -f (Get-Date -Format s), $priority, $path)
            }
        } catch {
            Write-Host ('  {0}: could not boost' -f $process.ProcessName) -ForegroundColor DarkYellow
        }
    }
    if ($sessionLines.Count -gt 0) { $sessionLines | Add-Content -LiteralPath $SessionLog }
    Write-Host
    Write-Host 'SESSION BOOST ACTIVE.' -ForegroundColor Green
    Write-Host 'DSCP helps only when the router/SQM honors it; it cannot reduce physical route ping.'
    Read-Host 'Press Enter to close'
}

function Find-RestoreAdapter($SavedAdapter) {
    $adapter = Get-NetAdapter -Name $SavedAdapter.Name -ErrorAction SilentlyContinue
    if ($null -eq $adapter) {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object InterfaceDescription -eq $SavedAdapter.InterfaceDescription |
            Select-Object -First 1
    }
    return $adapter
}

function Restore-MouseFromRegistry($RegistryStates) {
    $speed = @($RegistryStates | Where-Object Name -eq 'MouseSpeed')[0]
    $threshold1 = @($RegistryStates | Where-Object Name -eq 'MouseThreshold1')[0]
    $threshold2 = @($RegistryStates | Where-Object Name -eq 'MouseThreshold2')[0]
    $accel = if ($speed -and $speed.Exists) { [int]$speed.Value } else { 0 }
    $t1 = if ($threshold1 -and $threshold1.Exists) { [int]$threshold1.Value } else { 0 }
    $t2 = if ($threshold2 -and $threshold2.Exists) { [int]$threshold2.Value } else { 0 }
    Set-MouseAcceleration -Threshold1 $t1 -Threshold2 $t2 -Acceleration $accel
}

function Restore-Tuning {
    Write-Title
    if (-not (Request-Administrator -RequestedAction 'restore')) { return }
    if (-not (Test-Path -LiteralPath $StateFile)) {
        Write-Host 'No i3-12100 Realtek profile backup was found. Nothing was changed.' -ForegroundColor Yellow
        Read-Host 'Press Enter to close'
        return
    }
    $state = Import-Clixml -LiteralPath $StateFile
    Write-Host ('Restoring i3-12100 Realtek backup captured at {0}...' -f $state.CapturedAt)

    Remove-PersistentAutoBoost
    Write-Host 'Persistent AutoBoost -> Removed' -ForegroundColor Green

    foreach ($policy in @(Get-NetQosPolicy -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
        Where-Object Name -like ($QosPrefix + '*'))) {
        Remove-NetQosPolicy -Name $policy.Name -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
    }
    foreach ($path in @($state.PowerThrottlePaths)) {
        if ($path) { Invoke-PowerCfg @('/powerthrottling', 'reset', '/path', [string]$path) }
    }

    if ($state.GlobalRss -in @('Enabled', 'Disabled')) {
        try { Set-NetOffloadGlobalSetting -ReceiveSideScaling $state.GlobalRss -ErrorAction Stop | Out-Null } catch {}
    }
    if ($state.GlobalRsc -in @('Enabled', 'Disabled')) {
        try { Set-NetOffloadGlobalSetting -ReceiveSegmentCoalescing $state.GlobalRsc -ErrorAction Stop | Out-Null } catch {}
    }
    if ($state.GlobalPacketCoalescing -in @('Enabled', 'Disabled')) {
        try { Set-NetOffloadGlobalSetting -PacketCoalescingFilter $state.GlobalPacketCoalescing -ErrorAction Stop | Out-Null } catch {}
    }
    Write-Host 'Global offload settings -> original' -ForegroundColor Green

    foreach ($savedAdapter in @($state.Adapters)) {
        $adapter = Find-RestoreAdapter -SavedAdapter $savedAdapter
        if ($null -eq $adapter) {
            Write-Host ('Adapter not found: {0}' -f $savedAdapter.Name) -ForegroundColor DarkYellow
            continue
        }
        Write-Host ('Restoring adapter: {0}' -f $adapter.Name) -ForegroundColor Cyan
        $restartNeeded = $false
        foreach ($property in @($savedAdapter.Advanced)) {
            try {
                Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $property.RegistryKeyword `
                    -RegistryValue $property.RegistryValue -NoRestart -ErrorAction Stop | Out-Null
                $restartNeeded = $true
            } catch { Write-Host ('  Could not restore {0}' -f $property.RegistryKeyword) -ForegroundColor DarkYellow }
        }
        if ($savedAdapter.RssSupported) {
            try {
                Set-NetAdapterRss -Name $adapter.Name -Enabled ([bool]$savedAdapter.RssEnabled) -NoRestart -ErrorAction Stop | Out-Null
                $restartNeeded = $true
            } catch {}
        }
        if ($savedAdapter.Rsc.Supported) {
            try {
                Set-NetAdapterRsc -Name $adapter.Name -IPv4Enabled ([bool]$savedAdapter.Rsc.IPv4Enabled) `
                    -IPv6Enabled ([bool]$savedAdapter.Rsc.IPv6Enabled) -NoRestart -ErrorAction Stop | Out-Null
                $restartNeeded = $true
            } catch {}
        }
        if ($savedAdapter.Uso.Supported -and (Get-Command Set-NetAdapterUso -ErrorAction SilentlyContinue)) {
            try {
                Set-NetAdapterUso -Name $adapter.Name -IPv4Enabled ([bool]$savedAdapter.Uso.IPv4Enabled) `
                    -IPv6Enabled ([bool]$savedAdapter.Uso.IPv6Enabled) -NoRestart -ErrorAction Stop | Out-Null
                $restartNeeded = $true
            } catch {}
        }
        if ($savedAdapter.Power.Supported) {
            if (Set-AdapterPowerFeature -AdapterName $adapter.Name -Feature 'SelectiveSuspend' -Value $savedAdapter.Power.SelectiveSuspend) { $restartNeeded = $true }
            if (Set-AdapterPowerFeature -AdapterName $adapter.Name -Feature 'D0PacketCoalescing' -Value $savedAdapter.Power.D0PacketCoalescing) { $restartNeeded = $true }
            if (Set-AdapterPowerFeature -AdapterName $adapter.Name -Feature 'DeviceSleepOnDisconnect' -Value $savedAdapter.Power.DeviceSleepOnDisconnect) { $restartNeeded = $true }
        }
        if ($restartNeeded) {
            try { Restart-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop } catch {}
        }
    }

    foreach ($registryValue in @($state.Registry)) { Restore-RegistryValue -SavedValue $registryValue }
    Restore-MouseFromRegistry -RegistryStates @($state.Registry)
    Write-Host 'Game, capture and mouse settings -> original' -ForegroundColor Green

    if ($state.ActivePowerScheme) {
        Invoke-PowerCfg @('/setactive', [string]$state.ActivePowerScheme)
        Write-Host 'Power plan -> original' -ForegroundColor Green
    }
    if ($state.AggressivePowerScheme -and $state.AggressivePowerScheme -ne $state.ActivePowerScheme) {
        Invoke-PowerCfg @('/delete', [string]$state.AggressivePowerScheme)
    }

    $archive = Join-Path $DataDirectory ('restored-{0}.clixml' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item -LiteralPath $StateFile -Destination $archive -Force
    Write-Host
    Write-Host 'REALTEK PROFILE RESTORED. Restart Windows once.' -ForegroundColor Green
    Write-Host ('Archived backup: {0}' -f $archive) -ForegroundColor DarkGray
    Read-Host 'Press Enter to close'
}

function Show-Status {
    Write-Title
    if (-not (Request-Administrator -RequestedAction 'status')) { return }
    Write-Host ((& powercfg.exe /getactivescheme 2>&1 | Out-String).Trim())
    try {
        $global = Get-NetOffloadGlobalSetting -ErrorAction Stop
        Write-Host ('Global RSS={0}, RSC={1}, PacketCoalescing={2}' -f `
            $global.ReceiveSideScaling, $global.ReceiveSegmentCoalescing, $global.PacketCoalescingFilter)
    } catch {}
    Write-Host ('Realtek profile backup: {0}' -f $(if (Test-Path $StateFile) { 'Present' } else { 'Not present' }))
    try {
        $autoTask = Get-ScheduledTask -TaskName $AutoBoostTaskName -ErrorAction Stop
        Write-Host ('Persistent AutoBoost: {0}' -f $autoTask.State)
    } catch {
        Write-Host 'Persistent AutoBoost: Not installed'
    }
    Write-Host
    try {
        foreach ($adapter in @(Get-ActiveEthernetAdapters)) {
            Write-Host ('{0} - {1}' -f $adapter.Name, $adapter.LinkSpeed) -ForegroundColor Cyan
            try { $rss = Get-NetAdapterRss -Name $adapter.Name -ErrorAction Stop; Write-Host ('  RSS: {0}' -f $rss.Enabled) } catch {}
            try { $rsc = Get-NetAdapterRsc -Name $adapter.Name -ErrorAction Stop; Write-Host ('  RSC IPv4/IPv6: {0}/{1}' -f $rsc.IPv4Enabled, $rsc.IPv6Enabled) } catch {}
            try { $uso = Get-NetAdapterUso -Name $adapter.Name -ErrorAction Stop; Write-Host ('  USO IPv4/IPv6: {0}/{1}' -f $uso.IPv4Enabled, $uso.IPv6Enabled) } catch {}
            try {
                Get-NetAdapterAdvancedProperty -Name $adapter.Name -AllProperties -ErrorAction Stop |
                    Where-Object { $TargetAdvancedKeywords -contains $_.RegistryKeyword } |
                    ForEach-Object { Write-Host ('  {0}: {1}' -f $_.RegistryKeyword, ($_.RegistryValue -join ',')) }
            } catch {}
        }
    } catch { Write-Host ('Adapter query failed: {0}' -f $_.Exception.Message) -ForegroundColor Red }
    Write-Host
    Read-Host 'Press Enter to close'
}

function Show-Menu {
    Write-Title
    Write-Host '1. Apply i3-12100/GTX1650/Realtek profile + AutoBoost'
    Write-Host '2. Start manual FiveM Session Boost (fallback)'
    Write-Host '3. Show current status'
    Write-Host '4. Restore original i3-12100 Realtek baseline'
    Write-Host '5. Exit'
    Write-Host
    switch (Read-Host 'Choose 1-5') {
        '1' { Apply-Tuning }
        '2' { Start-SessionBoost }
        '3' { Show-Status }
        '4' { Restore-Tuning }
        default { return }
    }
}

switch ($Action.ToLowerInvariant()) {
    'apply'    { Apply-Tuning }
    'session'  { Start-SessionBoost }
    'status'   { Show-Status }
    'restore'  { Restore-Tuning }
    'selftest' { Write-Host 'FiveM i3-12100 Realtek tailored engine self-test: OK' }
    default    { Show-Menu }
}
'@

function Invoke-V8 {
    param([string]$Action)
    $old = $env:FMV4_ACTION
    try {
        $env:FMV4_ACTION = $Action
        & ([scriptblock]::Create($v8Source))
    } finally { $env:FMV4_ACTION = $old }
}

function Invoke-Realtek {
    param([string]$Action)
    $old = $env:FIVEM_V2_ACTION
    try {
        $env:FIVEM_V2_ACTION = $Action
        & ([scriptblock]::Create($realtekSource))
    } finally { $env:FIVEM_V2_ACTION = $old }
}

switch ($RequestedAction) {
    'install' { Invoke-V8 'install'; Invoke-Realtek 'apply' }
    'apply'   { Invoke-V8 'install'; Invoke-Realtek 'apply' }
    'start'   { Invoke-V8 'start' }
    'status'  { Invoke-V8 'status'; Invoke-Realtek 'status' }
    'remove'  { Invoke-V8 'remove'; Invoke-Realtek 'restore' }
    'restore' { Invoke-V8 'remove'; Invoke-Realtek 'restore' }
    'selftest' { Invoke-V8 'selftest'; Invoke-Realtek 'selftest' }
    default { Invoke-V8 'install'; Invoke-Realtek 'apply' }
}

<#
.SYNOPSIS
    Provisions a Windows 11 device from en-US/US to fr-CA + en-CA with the
    Canadian Multilingual Standard (CMS) keyboard.

.DESCRIPTION
    Single NinjaOne script, runs as SYSTEM. Covers the four layers that have to
    be set independently -- missing any one of them is what leaves a device
    half-translated:

      1. Payload    Language packs + every Feature-on-Demand (spell check,
                    handwriting, OCR, speech, TTS). Verified after install,
                    not assumed.
      2. System     Preferred UI language, non-Unicode system locale, GeoID.
      3. Defaults   Welcome screen, system accounts, and the Default User hive
                    that every future profile is cloned from.
      4. Per user   Existing and future profiles, via Active Setup plus a
                    direct PreferredUILanguages write.

.PARAMETER AuditOnly
    Reports compliance and changes nothing. Exit 0 = compliant, 1 = not.
    Use this as the condition on a NinjaOne monitored-state automation.

.NOTES
    NinjaOne settings: Run As = System, Architecture = 64-bit,
    script timeout >= 120 min. Measured on a clean en-US Windows 11 26200
    device, Install-Language took 44 min for fr-CA and 19 min for en-CA, so
    the default one-hour timeout kills the run partway through.

    A reboot is required before the result is fully visible, but this script
    does not reboot. Run it during the day, then reboot out of hours (e.g.
    midnight). Re-running is safe and fast once the packs are present.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]   $PrimaryLanguage   = 'fr-CA',
    [string[]] $SecondaryLanguages = @('en-CA'),

    # Canadian Multilingual Standard. Verified against
    # HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts.
    [string]   $KeyboardLayoutId  = '00011009',

    [int]      $GeoId             = 39,          # Canada

    # Non-Unicode system locale. Turn off if you have legacy LOB apps that
    # choke on a French ANSI codepage.
    [bool]     $SetSystemLocale   = $true,

    [string]   $TimeZone          = '',          # e.g. 'Eastern Standard Time'

    # Chrome and Edge carry their own Hunspell dictionaries and ignore the OS
    # spell checker entirely, so the language packs above do nothing for them.
    # Chromium has no fr-CA dictionary; French is the single 'fr' entry.
    [bool]     $ConfigureBrowsers = $true,
    [string[]] $BrowserSpellcheckLanguages = @('fr', 'en-CA', 'en-US'),

    # Kept so existing NinjaOne jobs that still pass this do not fail.
    # The script never reboots; schedule a midnight reboot separately.
    [int]      $RebootDelaySeconds = 0,

    [switch]   $AuditOnly
)

$ErrorActionPreference = 'Stop'

$Script:LogPrefix          = '[CA-Lang]'
$Script:PayloadDir   = Join-Path $env:ProgramData 'CanadianLanguage'
$Script:PayloadPath  = Join-Path $Script:PayloadDir 'Apply-UserLanguage.ps1'
$Script:LogFile      = Join-Path $Script:PayloadDir 'provision.log'
$Script:PolicyBackupFile = Join-Path $Script:PayloadDir 'policy-backup.json'
$Script:ActiveSetupId = '{8C5F1A2E-4B7D-4E19-9F3C-CA0C10091001}'
$Script:PayloadVersion = '3,0,0,0'   # bump to force Active Setup to re-run per user
$Script:PolicyBackup = New-Object System.Collections.Generic.List[object]
$Script:Warnings     = New-Object System.Collections.Generic.List[string]
$Script:InstalledSomething = $false

function Write-Log {
    param(
        [string] $Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )
    Write-Host ('{0} {1} [{2}] {3}' -f (Get-Date -Format 'HH:mm:ss'), $Script:LogPrefix, $Level, $Message)
    if ($Level -eq 'WARN' -or $Level -eq 'ERROR') { $Script:Warnings.Add($Message) }

    # Ninja only keeps the last run's console output, so keep a local trail for
    # the device you eventually have to troubleshoot by hand.
    try {
        if (-not (Test-Path $Script:PayloadDir)) {
            New-Item -Path $Script:PayloadDir -ItemType Directory -Force | Out-Null
        }
        Add-Content -Path $Script:LogFile -Encoding UTF8 -Value (
            '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    }
    catch { }
}

function Set-NinjaField {
    # Optional: only writes if the custom field exists in your NinjaOne tenant.
    # Create caLanguageStatus / caLanguageDetail / caLanguageChecked to use it.
    # When a field is missing, Ninja-Property-Set reports it on stderr rather
    # than throwing, so try/catch does not suppress it and every device without
    # the fields shows red errors in the script result. *>$null does.
    param([string] $Name, [string] $Value)
    $cmd = Get-Command 'Ninja-Property-Set' -ErrorAction SilentlyContinue
    if ($cmd) { try { & $cmd $Name $Value *>$null } catch { } }
}

#region Environment guards -----------------------------------------------------

# NinjaOne can hand the script to the 32-bit host. Under SysWOW64 the language
# cmdlets and Get-WindowsCapability see a redirected view and quietly misbehave,
# so bounce into the native host before doing anything else.
if ($env:PROCESSOR_ARCHITEW6432) {
    $native = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $native) {
        Write-Host "$Script:LogPrefix Relaunching in 64-bit PowerShell."
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
        foreach ($kv in $PSBoundParameters.GetEnumerator()) {
            if ($kv.Value -is [switch]) {
                if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
            }
            elseif ($kv.Value -is [array]) {
                $argList += "-$($kv.Key)"; $argList += ($kv.Value -join ',')
            }
            else {
                $argList += "-$($kv.Key)"; $argList += "$($kv.Value)"
            }
        }
        & $native $argList
        exit $LASTEXITCODE
    }
    Write-Host "$Script:LogPrefix WARNING: 32-bit host and SysNative unavailable; continuing."
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-RegExe {
    # ProcessStartInfo so French/English stderr from reg.exe cannot become a
    # terminating NativeCommandError under $ErrorActionPreference Stop.
    param([Parameter(Mandatory)][string[]] $ArgumentList)

    $quoted = foreach ($a in $ArgumentList) {
        if ($a -match '[\s"]') { '"{0}"' -f ($a -replace '"', '\"') } else { $a }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\reg.exe'
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = [Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    [pscustomobject]@{
        ExitCode = $p.ExitCode
        Output   = (($stdout + $stderr) -replace '\s+', ' ').Trim()
    }
}

function Dismount-RegistryHive {
    # NTUSER.DAT stays mapped until the Registry provider's handles are
    # finalized. One Collect + 500 ms is not enough on a busy PC, and a failed
    # unload used to abort the whole Ninja run after the language work succeeded.
    param(
        [Parameter(Mandatory)][string] $Name,
        [string] $Context = ''
    )

    foreach ($n in 1..10) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        $result = Invoke-RegExe -ArgumentList @('unload', $Name)
        if ($result.ExitCode -eq 0) { return }
        Start-Sleep -Milliseconds (200 * $n)
    }

    $where = if ($Context) { " ($Context)" } else { '' }
    Write-Log "Could not unload $Name$where. Settings were written; Windows will release the hive at reboot." 'WARN'
}

#endregion

#region Feature-on-Demand source policy ----------------------------------------

# Add-WindowsCapability and Install-Language pull from Windows Update even when
# the device is pointed at WSUS. If the tenant blocks that redirect the packs
# install but their features do not, which is the classic "language is there but
# spell check is missing" failure. Neutralise only the policies that actually
# block on-demand content, and put them back exactly as found.
#
# NoAutoUpdate is deliberately left alone: it does not block on-demand content
# and flipping it can kick off an unplanned patch run mid-provisioning.

function Set-TemporaryPolicy {
    param([string] $Path, [string] $Name, $Value, [string] $Type = 'DWord')

    $keyExisted = Test-Path $Path
    $hadValue   = $false
    $oldValue   = $null

    if ($keyExisted) {
        $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $prop) { $hadValue = $true; $oldValue = $prop.$Name }
    }

    if ($hadValue -and $oldValue -eq $Value) { return $false }

    if (-not $keyExisted) { New-Item -Path $Path -Force | Out-Null }

    $Script:PolicyBackup.Add([pscustomobject]@{
        Path = $Path; Name = $Name; KeyExisted = $keyExisted
        HadValue = $hadValue; OldValue = $oldValue; Type = $Type
    })

    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Save-PolicyBackup
    Write-Log "Temporarily set $Path\$Name = $Value"
    return $true
}

function Save-PolicyBackup {
    try {
        if ($Script:PolicyBackup.Count -eq 0) {
            Remove-Item $Script:PolicyBackupFile -Force -ErrorAction SilentlyContinue
            return
        }
        if (-not (Test-Path $Script:PayloadDir)) {
            New-Item -Path $Script:PayloadDir -ItemType Directory -Force | Out-Null
        }
        $Script:PolicyBackup | ConvertTo-Json -Depth 3 |
            Set-Content -Path $Script:PolicyBackupFile -Encoding UTF8
    }
    catch { }
}

function Restore-OrphanedPolicyBackup {
    # If a previous run was killed by the NinjaOne script timeout, the finally
    # block never ran and the device is still sitting with its Windows Update
    # source policies loosened. Put them back before doing anything else.
    if (-not (Test-Path $Script:PolicyBackupFile)) { return }

    Write-Log 'Previous run did not finish; restoring its policy backup first.' 'WARN'
    try {
        $saved = Get-Content $Script:PolicyBackupFile -Raw | ConvertFrom-Json
        $Script:PolicyBackup.Clear()
        foreach ($item in @($saved)) { $Script:PolicyBackup.Add($item) }
        Restore-TemporaryPolicies
    }
    catch {
        Write-Log "Could not replay policy backup: $($_.Exception.Message)" 'WARN'
        Remove-Item $Script:PolicyBackupFile -Force -ErrorAction SilentlyContinue
    }
}

function Restore-TemporaryPolicies {
    for ($i = $Script:PolicyBackup.Count - 1; $i -ge 0; $i--) {
        $b = $Script:PolicyBackup[$i]
        try {
            if ($b.HadValue) {
                New-ItemProperty -Path $b.Path -Name $b.Name -Value $b.OldValue `
                    -PropertyType $b.Type -Force | Out-Null
            }
            else {
                Remove-ItemProperty -Path $b.Path -Name $b.Name -ErrorAction SilentlyContinue
                if (-not $b.KeyExisted) {
                    Remove-Item -Path $b.Path -Force -ErrorAction SilentlyContinue
                }
            }
            Write-Log "Restored $($b.Path)\$($b.Name)"
        }
        catch {
            Write-Log "Could not restore $($b.Path)\$($b.Name): $($_.Exception.Message)" 'WARN'
        }
    }
    $Script:PolicyBackup.Clear()
    Save-PolicyBackup
}

function Test-Prerequisite {
    $ok = $true

    $drive  = Get-PSDrive -Name $env:SystemDrive.Substring(0, 1) -ErrorAction SilentlyContinue
    $freeGb = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGb -lt 4) {
        Write-Log "Only $freeGb GB free on $env:SystemDrive; language content needs about 4 GB." 'ERROR'
        $ok = $false
    }
    else {
        Write-Log "Free space on $env:SystemDrive : $freeGb GB"
    }

    # Warning only, until it is confirmed as a hard blocker. Seen on a device
    # where Install-Language failed in seconds with 0x80073CF1 and the
    # Language.* capabilities would not install while this flag was set.
    $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    if (Test-Path $cbs) {
        Write-Log 'Windows servicing has a reboot pending; language installs are likely to fail until the device restarts.' 'WARN'
    }

    # Warning only. A proxy can block this probe while the Delivery Optimization
    # path still works, so it is not worth failing the run over.
    $reachable = Test-NetConnection -ComputerName 'tlu.dl.delivery.mp.microsoft.com' `
        -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $reachable) {
        Write-Log 'Cannot reach the Microsoft content CDN on 443; downloads may fail.' 'WARN'
    }

    $ok
}

function Unblock-FeatureOnDemandSource {
    $wu        = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $wuAu      = "$wu\AU"
    $servicing = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing'

    $restartWu = $false

    # 2 = always download repair content and optional features straight from
    # Windows Update, ignoring WSUS.
    Set-TemporaryPolicy -Path $servicing -Name 'RepairContentServerSource' -Value 2 | Out-Null

    foreach ($name in @('UseWUServer')) {
        $current = (Get-ItemProperty -Path $wuAu -Name $name -ErrorAction SilentlyContinue).$name
        if ($current -eq 1) {
            if (Set-TemporaryPolicy -Path $wuAu -Name $name -Value 0) { $restartWu = $true }
        }
    }

    foreach ($name in @('DoNotConnectToWindowsUpdateInternetLocations',
                        'SetPolicyDrivenUpdateSourceForFeatureUpdates',
                        'SetPolicyDrivenUpdateSourceForQualityUpdates')) {
        $current = (Get-ItemProperty -Path $wu -Name $name -ErrorAction SilentlyContinue).$name
        if ($current -eq 1) {
            if (Set-TemporaryPolicy -Path $wu -Name $name -Value 0) { $restartWu = $true }
        }
    }

    if ($restartWu) {
        Write-Log 'Restarting Windows Update service to pick up the source change.'
        Restart-Service wuauserv -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    }

    if ((Get-Service wuauserv).StartType -eq 'Disabled') {
        Write-Log 'wuauserv is Disabled; language content cannot download. Enable it first.' 'ERROR'
    }
}

function Protect-InstalledLanguagePacks {
    # Stops the built-in maintenance task from reclaiming "unused" language packs
    # and silently reverting the device months later. Intentionally permanent.
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Control Panel\International'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'BlockCleanupOfUnusedPreinstalledLangPacks' `
        -Value 1 -PropertyType DWord -Force | Out-Null
}

#endregion

#region Language payload -------------------------------------------------------

function Get-LanguageCapabilityState {
    param([string[]] $Tags)

    $all = Get-WindowsCapability -Online -ErrorAction Stop
    $pattern = '^Language\.' + '.*~~~(' + (($Tags | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')~'
    $all | Where-Object { $_.Name -match $pattern } |
        Select-Object Name, State, @{ n = 'Tag'; e = { ($_.Name -split '~')[3] } }
}

function Get-InstalledLanguageList {
    # Get-InstalledLanguage hands its List<T> to the pipeline as a single object
    # instead of enumerating it, so `Get-InstalledLanguage | Where-Object` tests
    # against the whole collection rather than each language. foreach opens it
    # properly. Getting this wrong silently re-downloads every pack on re-run.
    $raw = Get-InstalledLanguage -ErrorAction SilentlyContinue
    if ($null -eq $raw) { return @() }
    $out = @()
    foreach ($item in $raw) { $out += $item }
    $out
}

function Install-TargetLanguage {
    param([string] $Tag, [switch] $RequireDisplayPack)

    $installed = @(Get-InstalledLanguageList | Where-Object { $_.LanguageId -eq $Tag })

    # Get-InstalledLanguage also lists a language that was only added for
    # typing (keyboard, spell check) with no display pack behind it. Skipping
    # on that alone leaves the primary language unusable and makes
    # Set-SystemPreferredUILanguage throw "Value does not fall within the
    # expected range". Secondary languages only need the typing features, and
    # en-CA has no display pack of its own, so only the primary is held to this.
    $present = $installed.Count -gt 0
    if ($present -and $RequireDisplayPack -and -not (Test-DisplayLanguageAvailable -Tag $Tag)) {
        Write-Log "$Tag is listed but its display language pack is missing; installing it." 'WARN'
        $present = $false
    }

    if ($present) {
        Write-Log "Language pack already present: $Tag"
        return
    }

    Write-Log "Installing language pack: $Tag (this can take 10-20 minutes)"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Install-Language -Language $Tag -ErrorAction Stop | Out-Null
            $Script:InstalledSomething = $true
            Write-Log "Installed: $Tag" 'OK'
            return
        }
        catch {
            Write-Log "Install-Language $Tag attempt $attempt failed: $($_.Exception.Message)" 'WARN'
            if ($attempt -lt 3) { Start-Sleep -Seconds 30 }
        }
    }
    throw "Install-Language failed for $Tag after 3 attempts."
}

function Install-MissingLanguageFeatures {
    param([string[]] $Tags)

    # Install-Language reports success even when individual Features on Demand
    # fail to download, so re-check and install the stragglers by name.
    # Language.Basic is the one that carries spell check and autocorrect.
    $missing = @(Get-LanguageCapabilityState -Tags $Tags |
        Where-Object { $_.State -ne 'Installed' })

    if ($missing.Count -eq 0) {
        Write-Log 'All language features already installed.' 'OK'
        return
    }

    Write-Log "Installing $($missing.Count) missing language feature(s)."
    foreach ($cap in $missing) {
        Write-Log "  + $($cap.Name)"
        try {
            Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
        }
        catch {
            $msg = $_.Exception.Message
            $state = (Get-WindowsCapability -Online -Name $cap.Name -ErrorAction SilentlyContinue).State
            if ($state -eq 'Installed') {
                Write-Log "  $($cap.Name) already present." 'OK'
            }
            else {
                Write-Log "  Failed: $($cap.Name) - $msg" 'WARN'
            }
        }
    }
}

function Test-DisplayLanguageAvailable {
    # Whether a language can actually be used as the Windows display language.
    # Install-Language may deliver either a full MUI pack (system-wide, under
    # C:\Windows\<tag>) or a Store-delivered Local Experience Pack (per user).
    # This key is the one place that reflects both, so check it rather than
    # guessing at Appx package names.
    param([string] $Tag)
    Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages\$Tag"
}

function Get-EffectiveKeyboardLayouts {
    # Windows records a non-default layout as the language's stock KLID in
    # Preload, plus a Substitutes entry pointing at what is really loaded.
    # Reading Preload on its own reports the wrong keyboard.
    param([string] $HivePath)

    $preload = Get-ItemProperty (Join-Path $HivePath 'Keyboard Layout\Preload') -ErrorAction SilentlyContinue
    if (-not $preload) { return @() }
    $subs = Get-ItemProperty (Join-Path $HivePath 'Keyboard Layout\Substitutes') -ErrorAction SilentlyContinue

    $preload.PSObject.Properties |
        Where-Object { $_.Name -match '^\d+$' } |
        Sort-Object { [int] $_.Name } |
        ForEach-Object {
            $klid = [string] $_.Value
            if ($subs -and $subs.PSObject.Properties[$klid]) { [string] $subs.$klid } else { $klid }
        }
}

#endregion

#region System-wide settings ---------------------------------------------------

function Set-SystemInternational {
    param([string] $Primary, [int] $Geo, [bool] $ApplySystemLocale)

    Write-Log "System preferred UI language: $Primary"
    Set-SystemPreferredUILanguage -Language $Primary

    if ($ApplySystemLocale) {
        Write-Log "System locale (non-Unicode programs): $Primary"
        Set-WinSystemLocale -SystemLocale $Primary
    }

    Write-Log "Home location: GeoID $Geo"
    Set-WinHomeLocation -GeoId $Geo
}

function Set-SystemAccountInternational {
    param([string] $Primary, [string[]] $All, [string] $Klid, [int] $Geo)

    # Copy-UserInternationalSettingsToSystem copies from *the calling user*.
    # Running as SYSTEM that means SYSTEM's own hive, so configure SYSTEM's
    # profile to the target state first, then push it to the Welcome screen and
    # the Default User template.
    Write-Log 'Staging international settings in the SYSTEM profile.'
    $list = New-WinUserLanguageList -Language $Primary
    $list[0].InputMethodTips.Clear()
    $list[0].InputMethodTips.Add((Get-InputTip -Tag $Primary -Klid $Klid))

    foreach ($tag in $All | Where-Object { $_ -ne $Primary }) {
        $list.Add($tag)
        $entry = $list | Where-Object { $_.LanguageTag -eq $tag } | Select-Object -First 1
        if ($entry) {
            $entry.InputMethodTips.Clear()
            $entry.InputMethodTips.Add((Get-InputTip -Tag $tag -Klid $Klid))
        }
    }

    Set-WinUserLanguageList -LanguageList $list -Force
    Set-Culture -CultureInfo $Primary
    Set-WinHomeLocation -GeoId $Geo
    Set-WinUILanguageOverride -Language $Primary

    Write-Log 'Copying to Welcome screen, system accounts, and new user defaults.'
    try {
        Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
        Write-Log 'Welcome screen and new-user defaults updated.' 'OK'
    }
    catch {
        Write-Log "Copy-UserInternationalSettingsToSystem failed: $($_.Exception.Message)" 'WARN'
        Write-Log 'Falling back to the intl.cpl unattend path.'
        Invoke-IntlCplFallback -Primary $Primary -All $All -Klid $Klid -Geo $Geo
    }
}

function Invoke-IntlCplFallback {
    param([string] $Primary, [string[]] $All, [string] $Klid, [int] $Geo)

    $inputs = New-Object System.Text.StringBuilder
    $isFirst = $true
    foreach ($tag in @($Primary) + @($All | Where-Object { $_ -ne $Primary })) {
        $tip = Get-InputTip -Tag $tag -Klid $Klid
        $default = if ($isFirst) { ' Default="true"' } else { '' }
        [void] $inputs.AppendLine("      <gs:InputLanguageID Action=`"add`" ID=`"$tip`"$default/>")
        $isFirst = $false
    }
    [void] $inputs.AppendLine('      <gs:InputLanguageID Action="remove" ID="0409:00000409"/>')

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<gs:GlobalizationServices xmlns:gs="urn:longhornGlobalizationUnattend">
  <gs:UserList>
    <gs:User UserID="Current" CopySettingsToDefaultUserAcct="true" CopySettingsToSystemAcct="true"/>
  </gs:UserList>
  <gs:UserLocale>
    <gs:Locale Name="$Primary" SetAsCurrent="true" ResetAllSettings="false"/>
  </gs:UserLocale>
  <gs:LocationPreferences>
    <gs:GeoID Value="$Geo"/>
  </gs:LocationPreferences>
  <gs:MUILanguagePreferences>
    <gs:MUILanguage Value="$Primary"/>
    <gs:MUIFallback Value="$($All | Where-Object { $_ -ne $Primary } | Select-Object -First 1)"/>
  </gs:MUILanguagePreferences>
  <gs:InputPreferences>
$($inputs.ToString().TrimEnd())
  </gs:InputPreferences>
</gs:GlobalizationServices>
"@

    $path = Join-Path $Script:PayloadDir 'intl-canada.xml'
    Set-Content -Path $path -Value $xml -Encoding UTF8
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\control.exe') `
        -ArgumentList "intl.cpl,,/f:`"$path`"" -Wait -WindowStyle Hidden
    Write-Log 'intl.cpl fallback applied.'
}

function Get-InputTip {
    param([string] $Tag, [string] $Klid)
    $langId = '{0:x4}' -f ([System.Globalization.CultureInfo]::GetCultureInfo($Tag)).LCID
    "$langId`:$Klid"
}

#endregion

#region Per-user application ---------------------------------------------------

function Write-UserPayload {
    param([string] $Primary, [string[]] $All, [string] $Klid, [int] $Geo)

    if (-not (Test-Path $Script:PayloadDir)) {
        New-Item -Path $Script:PayloadDir -ItemType Directory -Force | Out-Null
    }

    $tips = @()
    foreach ($tag in @($Primary) + @($All | Where-Object { $_ -ne $Primary })) {
        $tips += "@{ Tag = '$tag'; Tip = '$(Get-InputTip -Tag $tag -Klid $Klid)' }"
    }

    $header = @"
# Generated by Set-CanadianLanguage.ps1 -- do not edit by hand.
`$Primary = '$Primary'
`$Geo     = $Geo
`$Layout  = @($($tips -join ', '))
"@

    $body = @'

$ErrorActionPreference = 'SilentlyContinue'
Import-Module International

$list = New-WinUserLanguageList -Language $Primary
$list[0].InputMethodTips.Clear()
$list[0].InputMethodTips.Add($Layout[0].Tip)

foreach ($item in $Layout | Select-Object -Skip 1) {
    $list.Add($item.Tag)
    $entry = $list | Where-Object { $_.LanguageTag -eq $item.Tag } | Select-Object -First 1
    if ($entry) {
        $entry.InputMethodTips.Clear()
        $entry.InputMethodTips.Add($item.Tip)
    }
}

Set-WinUserLanguageList -LanguageList $list -Force
Set-Culture -CultureInfo $Primary
Set-WinHomeLocation -GeoId $Geo
Set-WinUILanguageOverride -Language $Primary
Set-WinDefaultInputMethodOverride -InputTip $Layout[0].Tip

# Settings > Time & language > Typing. Off by default on clean images, which
# makes the OS spell checker look broken even once Language.Basic is installed.
$typing = 'HKCU:\Software\Microsoft\TabletTip\1.7'
if (-not (Test-Path $typing)) { New-Item -Path $typing -Force | Out-Null }
New-ItemProperty -Path $typing -Name 'EnableSpellchecking'  -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $typing -Name 'EnableAutocorrection' -Value 1 -PropertyType DWord -Force | Out-Null
'@

    Set-Content -Path $Script:PayloadPath -Value ($header + $body) -Encoding UTF8
    Write-Log "Per-user payload written to $Script:PayloadPath"
}

function Register-UserPayloadActiveSetup {
    # Active Setup is the only built-in mechanism that runs once per profile at
    # logon and also catches profiles that already exist. Bumping PayloadVersion
    # re-runs it for everyone.
    $key = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$Script:ActiveSetupId"
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }

    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Set-ItemProperty -Path $key -Name '(Default)' -Value 'Canadian language settings (fr-CA / en-CA)'
    Set-ItemProperty -Path $key -Name 'StubPath' `
        -Value "`"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script:PayloadPath`""
    Set-ItemProperty -Path $key -Name 'Version'     -Value $Script:PayloadVersion
    Set-ItemProperty -Path $key -Name 'IsInstalled' -Value 1 -Type DWord

    Write-Log "Active Setup registered (version $Script:PayloadVersion)."
}

function Set-ExistingProfilesUiLanguage {
    param([string] $Primary)

    # Active Setup fixes the input list and locale at next logon, but the
    # display language is read at logon time. Writing PreferredUILanguages
    # directly into each profile hive makes it French on the very next sign-in
    # instead of the one after that.
    $profiles = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
        Where-Object { $_.PSChildName -match '^S-1-5-21-' }

    foreach ($userProfile in $profiles) {
        $sid  = $userProfile.PSChildName
        $path = (Get-ItemProperty $userProfile.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $path -or -not (Test-Path $path)) { continue }

        $loaded = Test-Path "Registry::HKEY_USERS\$sid"

        try {
            if ($loaded) {
                $desktop = "Registry::HKEY_USERS\$sid\Control Panel\Desktop"
                if (-not (Test-Path $desktop)) { New-Item -Path $desktop -Force | Out-Null }
                New-ItemProperty -Path $desktop -Name 'PreferredUILanguages' `
                    -Value @($Primary) -PropertyType MultiString -Force | Out-Null
                Write-Log "PreferredUILanguages set for $sid"
                continue
            }

            $dat = Join-Path $path 'NTUSER.DAT'
            if (-not (Test-Path $dat)) { continue }

            # Unique name per RID so a stuck unload cannot block the next profile.
            $hiveName = "HKU\CALang$($sid.Split('-')[-1])"
            $load = Invoke-RegExe -ArgumentList @('load', $hiveName, $dat)
            if ($load.ExitCode -ne 0) {
                Write-Log "Could not load hive for $sid; Active Setup will cover it." 'WARN'
                continue
            }

            try {
                $add = Invoke-RegExe -ArgumentList @(
                    'add', "$hiveName\Control Panel\Desktop",
                    '/v', 'PreferredUILanguages',
                    '/t', 'REG_MULTI_SZ',
                    '/d', $Primary,
                    '/f'
                )
                if ($add.ExitCode -eq 0) {
                    Write-Log "PreferredUILanguages set for $sid"
                }
                else {
                    Write-Log "Profile $sid : $($add.Output)" 'WARN'
                }
            }
            finally {
                Dismount-RegistryHive -Name $hiveName -Context $sid
            }
        }
        catch {
            Write-Log "Profile $sid : $($_.Exception.Message)" 'WARN'
        }
    }
}

function Invoke-PayloadForLoggedOnUser {
    # Applies immediately for whoever is signed in now, so the CMS keyboard and
    # regional formats are live without waiting for a reboot.
    $user = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Log 'No interactive user signed in; Active Setup will handle it at logon.'
        return
    }

    $taskName = 'CALang-ApplyUserSettings'
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $ps     = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $ps `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script:PayloadPath`""
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

        Register-ScheduledTask -TaskName $taskName -Action $action `
            -Principal $principal -Settings $settings | Out-Null
        Start-ScheduledTask -TaskName $taskName

        $deadline = (Get-Date).AddMinutes(3)
        do {
            Start-Sleep -Seconds 3
            $state = (Get-ScheduledTask -TaskName $taskName).State
        } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

        Write-Log "Applied to signed-in user $user." 'OK'
    }
    catch {
        Write-Log "Could not apply to $user now: $($_.Exception.Message)" 'WARN'
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

#endregion

#region Compliance -------------------------------------------------------------

function Get-ComplianceReport {
    param([string] $Primary, [string[]] $All, [string] $Klid)

    $tags   = @($Primary) + @($All | Where-Object { $_ -ne $Primary })
    $issues = New-Object System.Collections.Generic.List[string]

    # Everything below reads registry or the language list, so the audit works
    # unelevated and can back a NinjaOne condition without Run As = System.
    $languages = Get-InstalledLanguageList
    foreach ($tag in $tags) {
        $entry = $languages | Where-Object { $_.LanguageId -eq $tag } | Select-Object -First 1
        if (-not $entry) {
            $issues.Add("Language pack missing: $tag")
            continue
        }
        # BasicTyping carries spell check and autocorrect. Its absence is the
        # single most common reason French spell check appears broken.
        # LanguageFeatures is a [Flags] enum, so it stringifies to one
        # comma-joined value rather than a collection to test with -contains.
        if ("$($entry.LanguageFeatures)" -notmatch 'BasicTyping') {
            $issues.Add("Spell check / typing feature (BasicTyping) missing for $tag")
        }
    }

    if (-not (Test-DisplayLanguageAvailable -Tag $Primary)) {
        $issues.Add("$Primary is not available as a Windows display language")
    }

    $sysPreferred = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\Settings' `
        -Name 'PreferredUILanguages' -ErrorAction SilentlyContinue).PreferredUILanguages
    if ($sysPreferred -notcontains $Primary) {
        $issues.Add("System preferred UI language is not $Primary (found: $($sysPreferred -join ','))")
    }

    if ($SetSystemLocale) {
        # Read the pending registry value, not Get-WinSystemLocale: the live
        # value only catches up after a reboot, so the API reports the old
        # locale on an otherwise correctly configured device.
        $expectedLcid = '{0:x4}' -f ([System.Globalization.CultureInfo]::GetCultureInfo($Primary)).LCID
        $actualLcid = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' `
            -Name 'Default' -ErrorAction SilentlyContinue).Default
        if ($actualLcid -ne $expectedLcid) {
            $issues.Add("System locale is '$actualLcid', expected '$expectedLcid' ($Primary)")
        }
    }

    $welcome = (Get-ItemProperty 'Registry::HKEY_USERS\.DEFAULT\Control Panel\International' `
        -Name 'LocaleName' -ErrorAction SilentlyContinue).LocaleName
    if ($welcome -ne $Primary) {
        $issues.Add("Welcome screen locale is '$welcome', expected '$Primary'")
    }

    $welcomeKlids = @(Get-EffectiveKeyboardLayouts -HivePath 'Registry::HKEY_USERS\.DEFAULT')
    $unexpected = @($welcomeKlids | Where-Object { $_ -ne $Klid })
    if ($welcomeKlids.Count -eq 0 -or $unexpected.Count -gt 0) {
        $issues.Add("Welcome screen keyboards resolve to '$($welcomeKlids -join ',')', expected only '$Klid'")
    }

    $asKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$Script:ActiveSetupId"
    $asVersion = (Get-ItemProperty $asKey -Name 'Version' -ErrorAction SilentlyContinue).Version
    if ($asVersion -ne $Script:PayloadVersion) {
        $issues.Add("Per-user Active Setup is at '$asVersion', expected '$Script:PayloadVersion'")
    }

    if ($ConfigureBrowsers) {
        foreach ($entry in (Get-BrowserPolicyRoots).GetEnumerator()) {
            $enabled = (Get-ItemProperty $entry.Value -Name 'SpellcheckEnabled' `
                -ErrorAction SilentlyContinue).SpellcheckEnabled
            $have = @(Get-BrowserSpellcheckLanguages -Root $entry.Value)
            $absent = @($BrowserSpellcheckLanguages | Where-Object { $have -notcontains $_ })
            if ($enabled -ne 1 -or $absent.Count -gt 0) {
                $issues.Add("$($entry.Key) spellcheck is [$($have -join ',')], expected [$($BrowserSpellcheckLanguages -join ',')]")
            }
        }
    }

    # Needs admin for reg load, so it only runs when elevated. Everything above
    # works unelevated, which keeps the plain audit usable as a condition.
    if (Test-IsAdministrator) {
        foreach ($finding in (Test-NewUserTemplate -Primary $Primary -Klid $Klid)) {
            $issues.Add($finding)
        }
    }

    $issues
}

function Get-BrowserPolicyRoots {
    @{
        Chrome = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
        Edge   = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    }
}

function Get-BrowserSpellcheckLanguages {
    param([string] $Root)
    $key = Join-Path $Root 'SpellcheckLanguage'
    if (-not (Test-Path $key)) { return @() }
    (Get-ItemProperty $key -ErrorAction SilentlyContinue).PSObject.Properties |
        Where-Object { $_.Name -match '^\d+$' } |
        Sort-Object { [int] $_.Name } |
        ForEach-Object { [string] $_.Value }
}

function Set-BrowserSpellcheckPolicy {
    param([string[]] $Languages)

    foreach ($entry in (Get-BrowserPolicyRoots).GetEnumerator()) {
        $root = $entry.Value
        if (-not (Test-Path $root)) { New-Item -Path $root -Force | Out-Null }
        New-ItemProperty -Path $root -Name 'SpellcheckEnabled' -PropertyType DWord `
            -Value 1 -Force | Out-Null

        # Rebuilt rather than merged so a stale en-US-only list cannot survive.
        $key = Join-Path $root 'SpellcheckLanguage'
        if (Test-Path $key) { Remove-Item $key -Recurse -Force }
        New-Item -Path $key -Force | Out-Null

        $index = 1
        foreach ($lang in $Languages) {
            New-ItemProperty -Path $key -Name "$index" -PropertyType String `
                -Value $lang -Force | Out-Null
            $index++
        }
        Write-Log "$($entry.Key) spellcheck: $($Languages -join ', ')"
    }
    Write-Log 'Browsers must be fully quit and reopened to pick this up.'
}

function Test-NewUserTemplate {
    # C:\Users\Default\NTUSER.DAT is the template every new local account is
    # cloned from. It is NOT the same as HKEY_USERS\.DEFAULT, which is the
    # welcome screen. Without AD or Intune this file is the only thing making a
    # newly created account French, so verify it rather than assuming
    # Copy-UserInternationalSettingsToSystem did its job.
    param([string] $Primary, [string] $Klid)

    $found = New-Object System.Collections.Generic.List[string]
    $dat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path $dat)) {
        $found.Add('New-user template (Default\NTUSER.DAT) not found')
        return $found
    }

    $hiveName = "HKU\CAAudit$PID"
    $load = Invoke-RegExe -ArgumentList @('load', $hiveName, $dat)
    if ($load.ExitCode -ne 0) {
        $found.Add('New-user template could not be read (hive in use)')
        return $found
    }

    try {
        $hive = "Registry::HKEY_USERS\$($hiveName.Split('\')[-1])"

        $locale = (Get-ItemProperty "$hive\Control Panel\International" `
            -Name 'LocaleName' -ErrorAction SilentlyContinue).LocaleName
        if ($locale -ne $Primary) {
            $found.Add("New-user template locale is '$locale', expected '$Primary'")
        }

        $ui = (Get-ItemProperty "$hive\Control Panel\Desktop" `
            -Name 'PreferredUILanguages' -ErrorAction SilentlyContinue).PreferredUILanguages
        if ($ui -notcontains $Primary) {
            $found.Add("New-user template display language is '$($ui -join ',')', expected '$Primary'")
        }

        $klids = @(Get-EffectiveKeyboardLayouts -HivePath $hive)
        if ($klids.Count -eq 0 -or @($klids | Where-Object { $_ -ne $Klid }).Count -gt 0) {
            $found.Add("New-user template keyboards resolve to '$($klids -join ',')', expected only '$Klid'")
        }
    }
    finally {
        $locale = $null
        $ui = $null
        $klids = $null
        Dismount-RegistryHive -Name $hiveName -Context 'Default NTUSER.DAT'
    }

    $found
}

#endregion

#region Main -------------------------------------------------------------------

$allTags = @($PrimaryLanguage) + @($SecondaryLanguages | Where-Object { $_ -ne $PrimaryLanguage })

if ($AuditOnly) {
    $issues = Get-ComplianceReport -Primary $PrimaryLanguage -All $allTags -Klid $KeyboardLayoutId
    foreach ($issue in $issues) { Write-Log $issue 'WARN' }
    if ($issues.Count -eq 0) {
        Write-Output "COMPLIANT|$env:COMPUTERNAME|$($allTags -join ',')|$KeyboardLayoutId"
        exit 0
    }
    Write-Output "NONCOMPLIANT|$env:COMPUTERNAME|$($issues.Count) issue(s)"
    exit 1
}

if (-not (Test-IsAdministrator)) {
    Write-Log 'Administrator rights required. In NinjaOne set Run As = System.' 'ERROR'
    exit 2
}

if (-not (Get-Command Install-Language -ErrorAction SilentlyContinue)) {
    Write-Log 'LanguagePackManagement module missing. Requires Windows 10 20H2+ or Windows 11.' 'ERROR'
    exit 3
}

Write-Log "Target: $($allTags -join ' + ')  keyboard $KeyboardLayoutId  GeoID $GeoId"

# Baseline taken before anything is touched. A device that was already correct
# and needed no pack installed does not need a reboot, so a scheduled re-run
# should not keep reporting one.
$initialIssues = Get-ComplianceReport -Primary $PrimaryLanguage -All $allTags -Klid $KeyboardLayoutId

try {
    if (-not (Test-Path $Script:PayloadDir)) {
        New-Item -Path $Script:PayloadDir -ItemType Directory -Force | Out-Null
    }

    Restore-OrphanedPolicyBackup
    if (-not (Test-Prerequisite)) { exit 4 }

    Unblock-FeatureOnDemandSource
    Protect-InstalledLanguagePacks

    foreach ($tag in $allTags) {
        Install-TargetLanguage -Tag $tag -RequireDisplayPack:($tag -eq $PrimaryLanguage)
    }
    Install-MissingLanguageFeatures -Tags $allTags

    # Everything after this point configures Windows to display $PrimaryLanguage.
    # Without the pack, Set-SystemPreferredUILanguage throws and the run dies
    # half-applied, so stop here with a clear reason instead. Re-running is safe.
    if (-not (Test-DisplayLanguageAvailable -Tag $PrimaryLanguage)) {
        $reason = "$PrimaryLanguage display language pack is still missing after install. " +
            'Check that Windows Update and the Microsoft Store can download content, then re-run.'
        Write-Log $reason 'ERROR'
        Set-NinjaField 'caLanguageStatus'  'FAILED (display pack missing)'
        Set-NinjaField 'caLanguageDetail'  $reason
        Set-NinjaField 'caLanguageChecked' (Get-Date -Format 'yyyy-MM-dd HH:mm')
        Write-Output "FAILED|$env:COMPUTERNAME|$PrimaryLanguage display pack missing"
        exit 5
    }
}
finally {
    Restore-TemporaryPolicies
}

Set-SystemInternational -Primary $PrimaryLanguage -Geo $GeoId -ApplySystemLocale $SetSystemLocale
Set-SystemAccountInternational -Primary $PrimaryLanguage -All $allTags `
    -Klid $KeyboardLayoutId -Geo $GeoId

Write-UserPayload -Primary $PrimaryLanguage -All $allTags -Klid $KeyboardLayoutId -Geo $GeoId
Register-UserPayloadActiveSetup
Set-ExistingProfilesUiLanguage -Primary $PrimaryLanguage
Invoke-PayloadForLoggedOnUser

if ($ConfigureBrowsers) {
    Set-BrowserSpellcheckPolicy -Languages $BrowserSpellcheckLanguages
}

if ($TimeZone) {
    Write-Log "Time zone: $TimeZone"
    Set-TimeZone -Id $TimeZone -ErrorAction SilentlyContinue
}

$issues = Get-ComplianceReport -Primary $PrimaryLanguage -All $allTags -Klid $KeyboardLayoutId
foreach ($issue in $issues) { Write-Log $issue 'WARN' }

$rebootNeeded = $Script:InstalledSomething -or $initialIssues.Count -gt 0

Write-Log '--- Summary ---'
Write-Log "Languages installed : $(((Get-InstalledLanguageList).LanguageId) -join ', ')"
Write-Log "Issues at start     : $($initialIssues.Count)"
Write-Log "Remaining issues    : $($issues.Count)"
Write-Log "Warnings            : $($Script:Warnings.Count)"

if ($rebootNeeded) {
    Write-Log 'REBOOT REQUIRED later to finish applying the display language. This script will not reboot.' 'OK'
    if ($RebootDelaySeconds -gt 0) {
        Write-Log "Ignoring -RebootDelaySeconds $RebootDelaySeconds; reboot is left to a separate midnight job." 'WARN'
    }
}
else {
    Write-Log 'Already compliant; nothing changed and no reboot is needed.' 'OK'
}

$status = if ($issues.Count -gt 0) { "PARTIAL ($($issues.Count) issue(s))" } else { 'OK' }
Set-NinjaField 'caLanguageStatus'  $status
Set-NinjaField 'caLanguageDetail'  (($issues -join '; ') -replace '\s+', ' ')
Set-NinjaField 'caLanguageChecked' (Get-Date -Format 'yyyy-MM-dd HH:mm')

$rebootTag = if ($rebootNeeded) { 'RebootRequired' } else { 'NoRebootNeeded' }

if ($issues.Count -gt 0) {
    Write-Output "PARTIAL|$env:COMPUTERNAME|$($issues.Count) issue(s)|$rebootTag"
    exit 0
}

Write-Output "SUCCESS|$env:COMPUTERNAME|$($allTags -join ',')|$KeyboardLayoutId|$rebootTag"
exit 0

#endregion


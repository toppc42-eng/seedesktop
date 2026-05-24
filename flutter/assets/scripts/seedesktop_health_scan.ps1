# SeeDesktop — full health scan for remote Windows sessions.
# Outputs one JSON object between <<<SEEDESK_HEALTH_START>>> / END markers.
# Sync: listed as Flutter asset (../scripts/ from flutter/pubspec.yaml).
#Requires -Version 5.1
$ErrorActionPreference = 'Continue'
$output = [ordered]@{
    schema_version = 1
    generated_at   = (Get-Date).ToUniversalTime().ToString('o')
    checks         = [System.Collections.ArrayList]@()
    errors         = [System.Collections.ArrayList]@()
}
function Add-Check {
    param(
        [string]$Id,
        [string]$Status,
        [string]$Detail,
        [switch]$Remediated
    )
    $c = @{
        id     = $Id
        status = $Status.ToLower()
        detail = $Detail
    }
    if ($Remediated) { $c.remediated = $true }
    [void]$output.checks.Add($c)
}

# --- Critical events (24h): System + Application separately ---
$since = (Get-Date).AddHours(-24)
$eventIds = 41, 6008, 1000, 1001, 55, 129, 7031
$totalEv = 0
foreach ($logName in @('System', 'Application')) {
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{
                LogName   = $logName
                StartTime = $since
                Id        = $eventIds
            } -ErrorAction SilentlyContinue)
        $totalEv += $ev.Count
    }
    catch {
        [void]$output.errors.Add("events_${logName}: $($_.Exception.Message)")
    }
}
$stEv = 'ok'
if ($totalEv -gt 0 -and $totalEv -le 5) { $stEv = 'warn' }
if ($totalEv -gt 5) { $stEv = 'critical' }
Add-Check -Id 'critical_events' -Status $stEv -Detail ("count={0}" -f $totalEv)

# --- Defender ---
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $ok = $mp.RealTimeProtectionEnabled -and $mp.AntivirusEnabled
    $st = if ($ok) { 'ok' } else { 'critical' }
    Add-Check -Id 'defender' -Status $st -Detail ("RTP={0}; AV={1}" -f $mp.RealTimeProtectionEnabled, $mp.AntivirusEnabled)
}
catch {
    Add-Check -Id 'defender' -Status 'unknown' -Detail ("reason: {0}" -f $_.Exception.Message)
    [void]$output.errors.Add("defender: $($_.Exception.Message)")
}

# --- Firewall profiles ---
try {
    $profiles = Get-NetFirewallProfile -ErrorAction Stop
    $bad = @($profiles | Where-Object { -not $_.Enabled })
    if ($bad.Count -eq 0) {
        Add-Check -Id 'firewall' -Status 'ok' -Detail 'all profiles enabled'
    }
    else {
        $names = ($bad.Name -join ',')
        Add-Check -Id 'firewall' -Status 'critical' -Detail ("disabled: {0}" -f $names)
    }
}
catch {
    Add-Check -Id 'firewall' -Status 'unknown' -Detail $_.Exception.Message
    [void]$output.errors.Add("firewall: $($_.Exception.Message)")
}

# --- Fixed disks (% free) ---
Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } | ForEach-Object {
    $letter = $_.DriveLetter
    if ($_.Size -gt 0) {
        $fp = [math]::Round(100.0 * $_.SizeRemaining / $_.Size, 1)
        $ds = 'ok'
        if ($fp -lt 20) { $ds = 'warn' }
        if ($fp -lt 10) { $ds = 'critical' }
        Add-Check -Id ("disk_{0}" -f $letter) -Status $ds -Detail ("{0}: {1}% free" -f $letter, $fp)
    }
}

# --- Memory & uptime & OS ---
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $tot = [double]$os.TotalVisibleMemorySize * 1024
    $free = [double]$os.FreePhysicalMemory * 1024
    $pused = 0
    if ($tot -gt 0) { $pused = [math]::Round(100.0 * ($tot - $free) / $tot, 1) }
    $ms = 'ok'
    if ($pused -ge 85) { $ms = 'warn' }
    if ($pused -ge 92) { $ms = 'critical' }
    Add-Check -Id 'memory' -Status $ms -Detail ("{0}% used" -f $pused)

    $uptDays = ([datetime]::Now - $os.LastBootUpTime).TotalDays
    $us = 'ok'
    if ($uptDays -gt 30) { $us = 'warn' }
    Add-Check -Id 'uptime' -Status $us -Detail ("{0:N1} days" -f $uptDays)

    Add-Check -Id 'os' -Status 'ok' -Detail (($os.Caption + ' ' + $os.Version).Trim())
}
catch {
    [void]$output.errors.Add("wmi_os: $($_.Exception.Message)")
    Add-Check -Id 'memory' -Status 'unknown' -Detail $_.Exception.Message
}

# --- Pending reboot (common registry hints) ---
$pending = $false
$reasons = [System.Collections.ArrayList]@()
try {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $pending = $true
        [void]$reasons.Add('WindowsUpdate')
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $pending = $true
        [void]$reasons.Add('CBS')
    }
}
catch { }
$prs = if ($pending) { 'warn' } else { 'ok' }
$rd = if ($reasons.Count -gt 0) { ($reasons -join ',') } else { 'none' }
Add-Check -Id 'pending_reboot' -Status $prs -Detail $rd

# --- Critical services + auto-remediation ---
$criticalSvcs = @(
    @{ Name = 'Spooler'; Id = 'service_print_spooler' },
    @{ Name = 'wuauserv'; Id = 'service_windows_update' },
    @{ Name = 'Dnscache'; Id = 'service_dns_client' }
)
foreach ($svc in $criticalSvcs) {
    try {
        $s = Get-Service -Name $svc.Name -ErrorAction Stop
        $remediated = $false
        if ($s.Status -ne 'Running') {
            try {
                Start-Service -Name $svc.Name -ErrorAction Stop
                $s = Get-Service -Name $svc.Name
                $remediated = $true
            }
            catch { }
        }
        if ($s.Status -eq 'Running') {
            if ($remediated) {
                Add-Check -Id $svc.Id -Status 'ok' -Detail 'started after stop' -Remediated
            }
            else {
                Add-Check -Id $svc.Id -Status 'ok' -Detail 'running'
            }
        }
        else {
            Add-Check -Id $svc.Id -Status 'critical' -Detail ("stopped; status={0}" -f $s.Status)
        }
    }
    catch {
        Add-Check -Id $svc.Id -Status 'unknown' -Detail $_.Exception.Message
        [void]$output.errors.Add("service $($svc.Name): $($_.Exception.Message)")
    }
}

# --- Network: DNS port + default gateway reachability ---
try {
    $dnsTest = Test-NetConnection -ComputerName '8.8.8.8' -Port 53 -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction SilentlyContinue
    Add-Check -Id 'net_dns_port' -Status $(if ($dnsTest) { 'ok' } else { 'warn' }) -Detail ("8.8.8.8:53 tcp={0}" -f $dnsTest)
}
catch {
    Add-Check -Id 'net_dns_port' -Status 'unknown' -Detail $_.Exception.Message
}

try {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    $gw = $route.NextHop
    if ($gw) {
        $ping = Test-Connection -ComputerName $gw -Count 1 -Quiet -ErrorAction SilentlyContinue
        Add-Check -Id 'net_gateway' -Status $(if ($ping) { 'ok' } else { 'critical' }) -Detail ("gateway {0} icmp={1}" -f $gw, $ping)
    }
    else {
        Add-Check -Id 'net_gateway' -Status 'warn' -Detail 'no default route'
    }
}
catch {
    Add-Check -Id 'net_gateway' -Status 'unknown' -Detail $_.Exception.Message
}

$json = ($output | ConvertTo-Json -Depth 12 -Compress)
Write-Output '<<<SEEDESK_HEALTH_START>>>'
Write-Output $json
Write-Output '<<<SEEDESK_HEALTH_END>>>'

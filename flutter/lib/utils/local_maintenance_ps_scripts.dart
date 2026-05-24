/// PowerShell script bodies for [LocalMaintenanceService] (no execution here).
/// Execution is delegated to the elevated background service via IPC.
library;

/// JSON: `{ "user_temp_bytes": int, "win_temp_bytes": int }`
String psEstimateTempFoldersJson() => r'''
$u = (Get-ChildItem -LiteralPath $env:TEMP -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
$w = (Get-ChildItem -LiteralPath "$env:windir\Temp" -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
$uN = if ($null -eq $u) { 0 } else { [int64]$u }
$wN = if ($null -eq $w) { 0 } else { [int64]$w }
(@{ user_temp_bytes = $uN; win_temp_bytes = $wN } | ConvertTo-Json -Compress)
''';

/// JSON: `{ "rx": int, "tx": int }` — cumulative bytes (run via admin IPC / SYSTEM).
/// Bulk [Get-NetAdapterStatistics], then per Up-adapter by name.
String psNetworkAdapterBytesJson() => r'''
$ErrorActionPreference = 'SilentlyContinue'
$rx=[int64]0;$tx=[int64]0
Get-NetAdapterStatistics -ErrorAction SilentlyContinue | ForEach-Object {
  $rx += [int64]$_.ReceivedBytes
  $tx += [int64]$_.SentBytes
}
if ($rx -eq 0 -and $tx -eq 0) {
  Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
    $st = Get-NetAdapterStatistics -Name $_.Name -ErrorAction SilentlyContinue
    if ($null -ne $st) {
      $rx += [int64]$st.ReceivedBytes
      $tx += [int64]$st.SentBytes
    }
  }
}
(@{ rx = $rx; tx = $tx } | ConvertTo-Json -Compress)
''';

/// Forensic metrics + OS caption (single JSON line).
String psForensicMetricsJson() => r'''
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$start30 = (Get-Date).AddDays(-30)
$start7 = (Get-Date).AddDays(-7)
$os = ''
try { $os = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption } catch { $os = '' }
$bsod = 0
try {
  $bsod = (@(Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001; StartTime=$start30} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -eq 'BugCheck' })).Count
} catch { $bsod = 0 }
$e41 = 0
try {
  $e41 = (@(Get-WinEvent -FilterHashtable @{LogName='System'; Id=41; StartTime=$start30} -ErrorAction SilentlyContinue)).Count
} catch { $e41 = 0 }
$e1000 = 0
$topCrash = ''
try {
  $e1000 = (@(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000; StartTime=$start30} -ErrorAction SilentlyContinue)).Count
  $evs = @(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000; StartTime=$start30} -MaxEvents 800 -ErrorAction SilentlyContinue)
  $names = $evs | ForEach-Object {
    $m = [regex]::Match($_.Message, '(?i)Faulting application name:\s*([^\s,]+)')
    if ($m.Success) { $m.Groups[1].Value } else { $null }
  } | Where-Object { $_ -and $_.Length -gt 0 }
  $g = $names | Group-Object | Sort-Object Count -Descending | Select-Object -First 1
  if ($g) { $topCrash = [string]$g.Name }
} catch { $e1000 = 0; $topCrash = '' }
$e4625 = -1
try {
  $e4625 = (@(Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625; StartTime=$start7} -ErrorAction SilentlyContinue)).Count
} catch { $e4625 = -1 }
(@{
  os_caption = [string]$os
  bsod_1001 = [int]$bsod
  unexpected_shutdown_41 = [int]$e41
  app_error_1000 = [int]$e1000
  top_crash_app = [string]$topCrash
  failed_logon_4625 = [int]$e4625
} | ConvertTo-Json -Compress)
''';

/// `DLCHAR` → drive letter (e.g. C).
String psChkdskVolumeScanTemplate() => r'''
$ErrorActionPreference = 'SilentlyContinue'
$dl = 'DLCHAR'
$r = ''
try {
  $scan = Repair-Volume -DriveLetter $dl -Scan -ErrorAction SilentlyContinue 2>&1 | Out-String
  if ($scan -and $scan.Length -gt 2) { $r = ("Repair-Volume -Scan (" + $dl + ":)`n" + $scan) }
} catch { }
if ($r.Length -lt 8) {
  try {
    $cmd = 'chkdsk ' + $dl + ':'
    $o = cmd /c $cmd 2>&1
    $r = ($o | Out-String)
  } catch { $r = 'לא ניתן להריץ בדיקת כונן (ייתכן שדרוש הרשאות מנהל).' }
}
$r
''';

/// JSON: `{ "state": "Running" | "Stopped" | "Unknown" }`
String psPrintSpoolerStatusJson() => r'''
$ErrorActionPreference = 'SilentlyContinue'
$s = Get-Service -Name Spooler -ErrorAction SilentlyContinue
$st = if ($null -eq $s) { 'Unknown' } else { $s.Status.ToString() }
(@{ state = $st } | ConvertTo-Json -Compress)
''';

/// JSON from WinSAT (`Get-CimInstance Win32_WinSAT`) for Windows Experience scores.
String psWinSatScoresJson() => r'''
$ErrorActionPreference = 'SilentlyContinue'
$w = $null
try { $w = Get-CimInstance -ClassName Win32_WinSAT -ErrorAction SilentlyContinue } catch { $w = $null }
if ($null -eq $w) {
  (@{ assessment_state = -1 } | ConvertTo-Json -Compress)
  return
}
(@{
  cpu_score = [double]$w.CPUScore
  d3d_score = [double]$w.D3DScore
  disk_score = [double]$w.DiskScore
  graphics_score = [double]$w.GraphicsScore
  memory_score = [double]$w.MemoryScore
  winspr_level = [double]$w.WinSPRLevel
  assessment_state = [int]$w.WinSATAssessmentState
  time_taken = [string]$w.TimeTaken
} | ConvertTo-Json -Compress)
''';

String psRestartPrintSpooler() => r'''
$ErrorActionPreference = 'Stop'
try {
  Restart-Service -Name Spooler -Force -ErrorAction Stop
  'OK'
} catch {
  $_.Exception.Message
}
''';

/// Single JSON for extended dashboard audit (RAM slots, network, AV, users, SMB, printers, USB).
/// Each subsection is best-effort; failures leave empty defaults.
String psDashboardExtendedAuditJson() => r'''
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$ramSlots = New-Object System.Collections.ArrayList
try {
  Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue | ForEach-Object {
    $lbl = if ($_.BankLabel) { [string]$_.BankLabel } elseif ($_.DeviceLocator) { [string]$_.DeviceLocator } else { 'Slot' }
    $cm = if ($_.Capacity) { [int]([double]$_.Capacity / 1MB) } else { 0 }
    [void]$ramSlots.Add(@{ label = $lbl; capacity_mb = $cm })
  }
} catch { }
$primaryMac = ''
try {
  $na = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MacAddress } | Select-Object -First 1
  if ($na) { $primaryMac = [string]$na.MacAddress }
} catch { }
$netUpCount = 0
try { $netUpCount = @(@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })).Count } catch { }
$arpList = New-Object System.Collections.ArrayList
try {
  Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^ff' } | Select-Object -First 48 | ForEach-Object {
    $ip = [string]$_.IPAddress
    $mac = [string]$_.LinkLayerAddress
    $nm = [string]$_.InterfaceAlias
    [void]$arpList.Add(@{ ip = $ip; name = $nm; mac = $mac })
  }
} catch { }
$avName = ''
try {
  $avp = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($avp) {
    $dn = $avp.displayName
    if (-not $dn) { $dn = $avp.DisplayName }
    if ($dn) { $avName = [string]$dn }
  }
} catch { }
if ([string]::IsNullOrWhiteSpace($avName)) {
  try {
    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
      $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
      if ($null -ne $mp) { $avName = 'Windows Defender' }
    }
  } catch { }
}
$localUsers = New-Object System.Collections.ArrayList
$activeUsers = 0
try {
  Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object {
    $en = [bool]$_.Enabled
    if ($en) { $activeUsers++ }
    $ll = ''
    try { if ($_.LastLogon) { $ll = $_.LastLogon.ToString('yyyy-MM-dd HH:mm') } } catch { }
    [void]$localUsers.Add(@{ name = [string]$_.Name; last_logon = $ll; enabled = $en })
  }
} catch { }
$computerName = [string]$env:COMPUTERNAME
$logonUser = ''
try {
  $wi = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  if ($wi) { $logonUser = [string]$wi.Name }
} catch { }
if ([string]::IsNullOrWhiteSpace($logonUser)) { $logonUser = [string]$env:USERNAME }
$motherboard = ''
try {
  $bb = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($bb) {
    $motherboard = ([string]$bb.Manufacturer + ' ' + [string]$bb.Product).Trim()
  }
} catch { }
$biosVer = ''
try {
  $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($bios) { $biosVer = [string]$bios.SMBIOSBIOSVersion }
} catch { }
$usbControllerCount = 0
try { $usbControllerCount = @(@(Get-CimInstance -ClassName Win32_USBController -ErrorAction SilentlyContinue)).Count } catch { }
$usbHubCount = 0
try { $usbHubCount = @(@(Get-CimInstance -ClassName Win32_USBHub -ErrorAction SilentlyContinue)).Count } catch { }
$storageControllerMode = ''
try {
  $ctrlNames = @()
  $ctrlNames += Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceClass -in @('SCSIAdapter','HDC','StorageController') -and $_.DeviceName } |
    ForEach-Object { [string]$_.DeviceName }
  if ($ctrlNames.Count -eq 0) {
    $ctrlNames += Get-CimInstance -ClassName Win32_IDEController -ErrorAction SilentlyContinue |
      ForEach-Object { [string]$_.Name }
    $ctrlNames += Get-CimInstance -ClassName Win32_SCSIController -ErrorAction SilentlyContinue |
      ForEach-Object { [string]$_.Name }
  }
  $joined = ($ctrlNames -join ' | ')
  $lower = $joined.ToLowerInvariant()
  if ($lower -match 'raid|rst|vmd|iastor') {
    $storageControllerMode = 'RAID / Intel RST'
  } elseif ($lower -match 'ahci|storahci') {
    $storageControllerMode = 'AHCI'
  } elseif ($lower -match '\bide\b|ata channel|standard dual channel') {
    $storageControllerMode = 'IDE / ATA'
  } elseif ($joined.Trim().Length -gt 0) {
    $storageControllerMode = ($ctrlNames | Select-Object -First 1)
  } else {
    $storageControllerMode = 'Unknown'
  }
} catch { $storageControllerMode = 'Unknown' }
$secureBoot = 'Unknown'
try {
  $sb = Confirm-SecureBootUEFI -ErrorAction Stop
  $secureBoot = if ($sb) { 'On' } else { 'Off' }
} catch { }
$osLicense = ''
try {
  $lic = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction SilentlyContinue |
    Where-Object { $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' -and $_.PartialProductKey } |
    Select-Object -First 1
  if ($lic) {
    $st = [int]$lic.LicenseStatus
    $osLicense = [string]$lic.Name
    if ($st -ge 0) { $osLicense = $osLicense + ' · Status ' + $st }
  }
} catch { }
$officeProducts = New-Object System.Collections.ArrayList
$microsoftProducts = New-Object System.Collections.ArrayList
try {
  $uninstallRoots = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  $names = Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue |
    ForEach-Object { [string]$_.DisplayName } |
    Where-Object { $_ -and $_.Trim().Length -gt 0 } |
    Select-Object -Unique
  $names | Where-Object { $_ -match '(?i)\b(Microsoft 365|Microsoft Office|Office\s+\d{4}|Office LTSC|Word|Excel|PowerPoint|Outlook)\b' } |
    Select-Object -First 8 | ForEach-Object { [void]$officeProducts.Add([string]$_) }
  $names | Where-Object { $_ -match '(?i)^Microsoft\s+' -and $_ -notmatch '(?i)(Visual C\+\+|Edge WebView|Update Health|OneDrive|Office|365)' } |
    Select-Object -First 10 | ForEach-Object { [void]$microsoftProducts.Add([string]$_) }
} catch { }
$audioDevices = New-Object System.Collections.ArrayList
try {
  Get-CimInstance -ClassName Win32_SoundDevice -ErrorAction SilentlyContinue |
    Select-Object -First 8 | ForEach-Object {
      $nm = [string]$_.Name
      $st = [string]$_.Status
      if ($nm) {
        if ($st) { [void]$audioDevices.Add(($nm + ' · ' + $st)) }
        else { [void]$audioDevices.Add($nm) }
      }
    }
} catch { }
$gpuAdapters = New-Object System.Collections.ArrayList
try {
  Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object {
    $nm = [string]$_.Name
    if (-not $nm) { $nm = '—' }
    $ramMb = 0
    try {
      if ($null -ne $_.AdapterRAM -and [int64]$_.AdapterRAM -gt 0) {
        $ramMb = [int][math]::Round([double]$_.AdapterRAM / 1MB, 0)
      }
    } catch { }
    $drv = [string]$_.DriverVersion
    if (-not $drv) { $drv = '' }
    $vm = [string]$_.VideoModeDescription
    if (-not $vm) { $vm = '' }
    $st = [string]$_.Status
    if (-not $st) { $st = '' }
    $w = 0; $h = 0
    try { if ($_.CurrentHorizontalResolution) { $w = [int]$_.CurrentHorizontalResolution } } catch { }
    try { if ($_.CurrentVerticalResolution) { $h = [int]$_.CurrentVerticalResolution } } catch { }
    $rr = ''
    try { if ($_.CurrentRefreshRate) { $rr = [string]$_.CurrentRefreshRate } } catch { }
    [void]$gpuAdapters.Add(@{
      name = $nm
      adapter_ram_mb = [int]$ramMb
      driver_version = $drv
      video_mode = $vm
      status = $st
      width = [int]$w
      height = [int]$h
      refresh_hz = $rr
    })
  }
} catch { }
$primaryGpu = ''
if ($gpuAdapters.Count -gt 0) {
  $primaryGpu = [string]$gpuAdapters[0].name
}
$physicalDisks = New-Object System.Collections.ArrayList
try {
  $pdById = @{}
  try {
    Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
      $id = [string]$_.DeviceId
      if ($id) { $pdById[$id] = $_ }
    }
  } catch { }
  $smartRows = @()
  try {
    $smartRows = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue)
  } catch { $smartRows = @() }
  Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue | Sort-Object Index | ForEach-Object {
    $idx = 0
    try { $idx = [int]$_.Index } catch { $idx = 0 }
    $model = [string]$_.Model
    $iface = [string]$_.InterfaceType
    $pnp = [string]$_.PNPDeviceID
    $status = [string]$_.Status
    $mediaType = ''
    $busType = $iface
    $health = ''
    $pd = $null
    if ($pdById.ContainsKey([string]$idx)) { $pd = $pdById[[string]$idx] }
    if ($null -ne $pd) {
      try {
        switch ([int]$pd.MediaType) {
          3 { $mediaType = 'HDD' }
          4 { $mediaType = 'SSD' }
          5 { $mediaType = 'SCM' }
          default { $mediaType = 'Unknown' }
        }
      } catch { }
      try {
        switch ([int]$pd.BusType) {
          7 { $busType = 'USB' }
          11 { $busType = 'SATA' }
          16 { $busType = 'NVMe' }
          17 { $busType = 'SCM' }
          default {
            if ($pd.BusType) { $busType = [string]$pd.BusType }
          }
        }
      } catch { }
      try { $health = [string]$pd.HealthStatus } catch { }
    }
    if (-not $mediaType) {
      if ($model -match '(?i)nvme|ssd') { $mediaType = 'SSD' }
      elseif ($model -match '(?i)hdd|ata') { $mediaType = 'HDD' }
      else { $mediaType = 'Unknown' }
    }
    $smart = ''
    try {
      $pnpNorm = ($pnp -replace '\\','_').ToUpperInvariant()
      $match = $smartRows | Where-Object {
        $inst = ([string]$_.InstanceName).ToUpperInvariant()
        $inst -and ($pnpNorm.Contains($inst) -or $inst.Contains($pnpNorm) -or $inst.Contains(([string]$_.Model).ToUpperInvariant()))
      } | Select-Object -First 1
      if ($match) { $smart = if ([bool]$match.PredictFailure) { 'SMART Warning' } else { 'SMART OK' } }
    } catch { }
    if (-not $smart) {
      if ($health -ne '') { $smart = 'Health: ' + $health }
      elseif ($status -ne '') { $smart = 'Status: ' + $status }
      else { $smart = 'Unknown' }
    }
    $parts = New-Object System.Collections.ArrayList
    try {
      $escapedDeviceId = ([string]$_.DeviceID).Replace('\','\\')
      Get-CimAssociatedInstance -InputObject $_ -Association Win32_DiskDriveToDiskPartition -ErrorAction SilentlyContinue | ForEach-Object {
        $partition = $_
        Get-CimAssociatedInstance -InputObject $partition -Association Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue | ForEach-Object {
          $total = 0.0; $free = 0.0
          try { if ($_.Size) { $total = [math]::Round([double]$_.Size / 1GB, 1) } } catch { }
          try { if ($_.FreeSpace) { $free = [math]::Round([double]$_.FreeSpace / 1GB, 1) } } catch { }
          [void]$parts.Add(@{
            id = [string]$_.DeviceID
            label = [string]$_.VolumeName
            total_gb = [double]$total
            free_gb = [double]$free
          })
        }
      }
    } catch { }
    [void]$physicalDisks.Add(@{
      index = [int]$idx
      model = $model
      disk_type = $mediaType
      bus_type = $busType
      port = if ($busType) { $busType } else { $iface }
      smart_status = $smart
      partitions = @($parts)
    })
  }
} catch { }
$printers = New-Object System.Collections.ArrayList
try {
  Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue | ForEach-Object {
    [void]$printers.Add(@{ name = [string]$_.Name; port = [string]$_.PortName })
  }
} catch { }
$usbNames = New-Object System.Collections.ArrayList
try {
  Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceType -eq 'USB' } |
    Select-Object -First 10 | ForEach-Object {
      $m = [string]$_.Model
      if ($m) { [void]$usbNames.Add($m) }
    }
} catch { }
(@{
  ram_slots = @($ramSlots)
  primary_mac = $primaryMac
  net_up_count = [int]$netUpCount
  arp_neighbors = @($arpList)
  antivirus = $avName
  local_users_active = [int]$activeUsers
  local_users = @($localUsers)
  computer_name = $computerName
  logon_user = $logonUser
  motherboard = $motherboard
  bios_version = $biosVer
  usb_controller_count = [int]$usbControllerCount
  usb_hub_count = [int]$usbHubCount
  storage_controller_mode = $storageControllerMode
  secure_boot = $secureBoot
  os_license = $osLicense
  office_products = @($officeProducts)
  microsoft_products = @($microsoftProducts)
  audio_devices = @($audioDevices)
  primary_gpu = $primaryGpu
  gpu_adapters = @($gpuAdapters)
  physical_disks = @($physicalDisks)
  printers = @($printers)
  usb_storage_recent = @($usbNames)
} | ConvertTo-Json -Depth 8 -Compress)
''';

/// Batch: `{ "services": [ { "name": "Spooler", "state": "Running" }, ... ] }`
/// [names] must be pre-validated (see [LocalMaintenanceService.isValidWatchdogServiceName]).
String psWindowsServicesStatusBatchJson(List<String> names) {
  if (names.isEmpty) {
    return r'(@{ services = @() } | ConvertTo-Json -Compress)';
  }
  final quoted = names.map((n) => "'${n.replaceAll("'", "''")}'").join(',');
  return r'''
$ErrorActionPreference = 'SilentlyContinue'
$names = @(''' +
      quoted +
      r''')
$out = New-Object System.Collections.ArrayList
foreach ($n in $names) {
  $s = Get-Service -Name $n -ErrorAction SilentlyContinue
  $st = if ($null -eq $s) { 'Unknown' } else { $s.Status.ToString() }
  [void]$out.Add(@{ name = $n; state = $st })
}
(@{ services = @($out.ToArray()) } | ConvertTo-Json -Compress -Depth 5)
''';
}

/// Starts each listed service if it exists and is not Running (best-effort).
String psStartWindowsServicesIfStopped(List<String> names) {
  if (names.isEmpty) {
    return r"Write-Output 'OK'";
  }
  final quoted = names.map((n) => "'${n.replaceAll("'", "''")}'").join(',');
  return r'''
$ErrorActionPreference = 'SilentlyContinue'
$names = @(''' +
      quoted +
      r''')
foreach ($n in $names) {
  $s = Get-Service -Name $n -ErrorAction SilentlyContinue
  if ($null -ne $s -and $s.Status.ToString() -ne 'Running') {
    try {
      Start-Service -Name $n -ErrorAction Stop
    } catch {
    }
  }
}
Write-Output 'OK'
''';
}

/// JSON: `{ TotalCPU, TotalRAM, Uptime, SwapTotalMB, SwapUsedMB, TopCPU[], TopRAM[] }` — עומס, קובץ החלפה, ועשרת התהליכים המובילים.
String psRealTimeLoadJson() => r'''
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$os = Get-CimInstance Win32_OperatingSystem
$ramPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
$swapTotalKb = [double]$os.SizeStoredInPagingFiles
$swapFreeKb = [double]$os.FreeSpaceInPagingFiles
$swapTotalMb = if ($swapTotalKb -gt 0) { [math]::Round($swapTotalKb / 1024, 1) } else { 0 }
$swapUsedMb = if ($swapTotalKb -gt 0) { [math]::Round(($swapTotalKb - $swapFreeKb) / 1024, 1) } else { 0 }
$uptime = (Get-Date) - $os.LastBootUpTime
$uptimeStr = "$($uptime.Days) Days, $($uptime.Hours) Hours"
$cpuProcs = Get-Process | Where-Object CPU -gt 0 | Sort-Object CPU -Descending | Select-Object -First 10
$topCPU = @()
foreach ($p in $cpuProcs) {
  $topCPU += @{ Name = $p.ProcessName; ID = $p.Id; CPU = [math]::Round($p.CPU, 1) }
}
$ramProcs = Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 10
$topRAM = @()
foreach ($p in $ramProcs) {
  $topRAM += @{ Name = $p.ProcessName; ID = $p.Id; RAM_MB = [math]::Round($p.WorkingSet / 1MB, 1) }
}
@{ TotalCPU = $cpu; TotalRAM = $ramPct; Uptime = $uptimeStr; SwapTotalMB = $swapTotalMb; SwapUsedMB = $swapUsedMb; TopCPU = $topCPU; TopRAM = $topRAM } | ConvertTo-Json -Depth 3
''';

/// JSON: `{ local_ipv4, public_ip }` — כתובת IPv4 מקומית וכתובת ציבורית (מחוץ לראוטר).
String psNetworkEndpointIpsJson() => r'''
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$local = ''
try {
  $cfg = Get-NetIPConfiguration | Where-Object { $null -ne $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
  if ($null -ne $cfg -and $null -ne $cfg.IPv4Address) { $local = [string]$cfg.IPv4Address.IPAddress }
} catch {}
if ([string]::IsNullOrWhiteSpace($local)) {
  try {
    $na = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($null -ne $na) {
      $ip = Get-NetIPAddress -InterfaceIndex $na.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254*' } | Select-Object -First 1
      if ($null -ne $ip) { $local = [string]$ip.IPAddress }
    }
  } catch {}
}
$pub = ''
try {
  $pub = ([string](Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 8 -UseBasicParsing)).Trim()
} catch {}
@{ local_ipv4 = [string]$local; public_ip = [string]$pub } | ConvertTo-Json -Compress
''';

/// JSON array (או אובייקט יחיד) של שגיאות Application אחרונות.
String psApplicationErrorsLast5Json() => r'''
$ErrorActionPreference = 'SilentlyContinue'
Get-EventLog -LogName Application -EntryType Error -Newest 5 -ErrorAction SilentlyContinue |
  Select-Object @{ N = 'Time'; E = { $_.TimeGenerated.ToString('yyyy-MM-dd HH:mm') } }, Source, Message |
  ConvertTo-Json -Depth 4
''';

/// JSON array (or single object) of recent unexpected shutdown events (System ID 41).
String psUnexpectedShutdownsLast5Json() => r'''
$ErrorActionPreference = 'SilentlyContinue'
Get-WinEvent -FilterHashtable @{LogName='System'; Id=41} -MaxEvents 5 -ErrorAction SilentlyContinue |
  Select-Object @{ N = 'Time'; E = { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') } }, ProviderName, LevelDisplayName, Message |
  ConvertTo-Json -Depth 4
''';

#Requires -Version 5.1
<#
.SYNOPSIS
  ניקוי מערכת Windows עם חלון בחירה (סימון)  - רץ על כל פרופילי המשתמשים תחת Users.

.DESCRIPTION
  מציג חלון GUI עם רשימת סוגי ניקוי. מנקה רק מה שסומן.
  מומלץ להריץ כמנהל (Administrator) לפריטים שמסומנים כ"דורש מנהל".

.NOTES
  הרצה:  powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\SystemCleanup_GUI.ps1
  או לחיצה כפולה אחרי הגדרת .ps1 לפתיחה ב-STA.
#>

# WinForms דורש apartment STA
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $MyInvocation.MyCommand.Path)
    foreach ($a in $args) { $argList += $a }
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argList -Wait
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Continue'
$script:LogPath = Join-Path $env:TEMP ("SeeDesktop_SystemCleanup_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-CleanupLog {
    param([string]$Message)
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UserProfileFolders {
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if (-not (Test-Path -LiteralPath $usersRoot)) { return @() }
    $skip = @('Public', 'Default', 'Default User', 'All Users')
    Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $skip -notcontains $_.Name } |
        ForEach-Object { $_.FullName }
}

function Remove-FolderContentsSafely {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-CleanupLog "דילוג (לא קיים): $Label"
        return 0
    }
    $bytes = 0
    try {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    if ($_.PSIsContainer) {
                        $len = (Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue |
                                Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                        if ($null -eq $len) { $len = 0 }
                        $bytes += [int64]$len
                        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    } else {
                        $bytes += $_.Length
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                } catch { }
            }
        Write-CleanupLog "נוקה: $Label (~ $([math]::Round($bytes/1MB, 1)) MB)"
    } catch {
        Write-CleanupLog "שגיאה ב-$Label : $($_.Exception.Message)"
    }
    return $bytes
}

function Clear-UserTempFolders {
    param([string[]]$ProfilePaths)
    foreach ($p in $ProfilePaths) {
        $t = Join-Path $p 'AppData\Local\Temp'
        Remove-FolderContentsSafely -Path $t -Label "Temp משתמש: $t"
    }
}

function Clear-WindowsTempFolder {
    $t = Join-Path $env:SystemRoot 'Temp'
    Remove-FolderContentsSafely -Path $t -Label "Windows\Temp"
}

function Clear-PrefetchFolder {
    if (-not (Test-IsAdmin)) {
        Write-CleanupLog "Prefetch: נדרשות הרשאות מנהל  - מדלג"
        return
    }
    $pf = Join-Path $env:SystemRoot 'Prefetch'
    if (Test-Path -LiteralPath $pf) {
        Get-ChildItem -LiteralPath $pf -Filter '*.pf' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Write-CleanupLog "נוקה: Prefetch (*.pf)"
    }
}

function Clear-ThumbnailCachePerUser {
    param([string[]]$ProfilePaths)
    foreach ($p in $ProfilePaths) {
        $thumb = Join-Path $p 'AppData\Local\Microsoft\Windows\Explorer'
        if (Test-Path -LiteralPath $thumb) {
            Get-ChildItem -LiteralPath $thumb -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Write-CleanupLog "נוקה: מטמון תמונות ממוזערות ב-$thumb"
        }
    }
}

function Clear-ChromeCachePerUser {
    param([string[]]$ProfilePaths)
    foreach ($p in $ProfilePaths) {
        $cache = Join-Path $p 'AppData\Local\Google\Chrome\User Data\Default\Cache'
        Remove-FolderContentsSafely -Path $cache -Label "Chrome Cache ($($p.Split('\')[-1]))"
        $code = Join-Path $p 'AppData\Local\Google\Chrome\User Data\Default\Code Cache'
        Remove-FolderContentsSafely -Path $code -Label "Chrome Code Cache ($($p.Split('\')[-1]))"
    }
}

function Clear-EdgeCachePerUser {
    param([string[]]$ProfilePaths)
    foreach ($p in $ProfilePaths) {
        $cache = Join-Path $p 'AppData\Local\Microsoft\Edge\User Data\Default\Cache'
        Remove-FolderContentsSafely -Path $cache -Label "Edge Cache ($($p.Split('\')[-1]))"
        $code = Join-Path $p 'AppData\Local\Microsoft\Edge\User Data\Default\Code Cache'
        Remove-FolderContentsSafely -Path $code -Label "Edge Code Cache ($($p.Split('\')[-1]))"
    }
}

function Clear-FirefoxCachePerUser {
    param([string[]]$ProfilePaths)
    foreach ($p in $ProfilePaths) {
        $ffRoot = Join-Path $p 'AppData\Local\Mozilla\Firefox\Profiles'
        if (-not (Test-Path -LiteralPath $ffRoot)) { continue }
        Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $c2 = Join-Path $_.FullName 'cache2'
            Remove-FolderContentsSafely -Path $c2 -Label "Firefox cache2 ($($p.Split('\')[-1]))"
        }
    }
}

function Clear-TeamsCachePerUser {
    param([string[]]$ProfilePaths)
    foreach ($p in $ProfilePaths) {
        $teams = Join-Path $p 'AppData\Roaming\Microsoft\Teams'
        if (-not (Test-Path -LiteralPath $teams)) { continue }
        @(
            (Join-Path $teams 'Cache'),
            (Join-Path $teams 'blob_storage'),
            (Join-Path $teams 'GPUCache'),
            (Join-Path $teams 'Code Cache')
        ) | ForEach-Object {
            Remove-FolderContentsSafely -Path $_ -Label "Teams: $_"
        }
    }
}

function Clear-DeliveryOptimizationCache {
    if (-not (Test-IsAdmin)) {
        Write-CleanupLog "Delivery Optimization: נדרש מנהל  - מדלג"
        return
    }
    $cache = 'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache'
    Remove-FolderContentsSafely -Path $cache -Label 'Delivery Optimization Cache'
}

function Clear-SoftwareDistributionDownload {
    if (-not (Test-IsAdmin)) {
        Write-CleanupLog "Windows Update Download: נדרש מנהל  - מדלג"
        return
    }
    $dl = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    try {
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Remove-FolderContentsSafely -Path $dl -Label 'SoftwareDistribution\Download'
    } finally {
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        Write-CleanupLog "שירות Windows Update הופעל מחדש"
    }
}

function Clear-WindowsErrorReportingCache {
    if (-not (Test-IsAdmin)) {
        Write-CleanupLog "WER ProgramData: נדרש מנהל  - מדלג"
        return
    }
    $wer = 'C:\ProgramData\Microsoft\Windows\WER'
    Remove-FolderContentsSafely -Path $wer -Label 'Windows Error Reporting (ProgramData)'
}

function Clear-RecycleBinAllDrives {
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-CleanupLog 'סל המחזור רוקן (כל הכוננים)'
    } catch {
        Write-CleanupLog "סל המחזור: $($_.Exception.Message)"
    }
}

function Clear-DnsClientCache {
    try {
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        ipconfig /flushdns | Out-Null
        Write-CleanupLog 'מטמון DNS נוקה (Clear-DnsClientCache + ipconfig /flushdns)'
    } catch {
        Write-CleanupLog "DNS: $($_.Exception.Message)"
    }
}

function Invoke-DismComponentCleanup {
    if (-not (Test-IsAdmin)) {
        Write-CleanupLog 'DISM StartComponentCleanup: נדרש מנהל  - מדלג'
        return
    }
    Write-CleanupLog 'מתחיל DISM /Online /Cleanup-Image /StartComponentCleanup (עשוי לארוך דקות)...'
    $p = Start-Process -FilePath DISM.exe -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup' -Wait -PassThru -NoNewWindow
    Write-CleanupLog "DISM הסתיים עם קוד יציאה: $($p.ExitCode)"
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# מפתח = מזהה פנימי, טקסט = תצוגה
$options = [ordered]@{
    'UserTemp'           = 'Temp מקומי לכל משתמש (AppData\Local\Temp)'
    'WindowsTemp'        = 'תיקיית Temp של Windows (Windows\Temp)'
    'Prefetch'           = 'Prefetch (דורש מנהל  - מוחק קבצי .pf)'
    'Thumbnails'         = 'מטמון תמונות ממוזערות (Explorer) לכל משתמש'
    'Chrome'             = 'מטמון Google Chrome (Cache + Code Cache)'
    'Edge'               = 'מטמון Microsoft Edge (Cache + Code Cache)'
    'Firefox'            = 'מטמון Mozilla Firefox (cache2)'
    'Teams'              = 'מטמון Microsoft Teams'
    'DeliveryOpt'        = 'מטמון Delivery Optimization (דורש מנהל)'
    'WinUpdateDl'        = 'הורדות Windows Update (SoftwareDistribution\Download)  - דורש מנהל, עוצר שירות זמנית'
    'WER'                = 'דוחות שגיאות Windows (WER ב-ProgramData)  - דורש מנהל'
    'RecycleBin'         = 'ריקון סל המחזור (כל הכוננים)'
    'DnsCache'           = 'ניקוי מטמון DNS'
    'DismComponent'      = 'DISM  - ניקוי מאגר רכיבים (כבד, דורש מנהל)'
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ניקוי מערכת  - בחר מה לנקות'
$form.Size = New-Object System.Drawing.Size(720, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Location = New-Object System.Drawing.Point(16, 12)
$lblTitle.Size = New-Object System.Drawing.Size(680, 40)
$lblTitle.Text = "הסקריפט יעבור על פרופילי המשתמשים תחת $($env:SystemDrive)\Users`n(למעט Public / Default) וינקה רק את הסעיפים שסומנים."
$form.Controls.Add($lblTitle)

$panel = New-Object System.Windows.Forms.Panel
$panel.Location = New-Object System.Drawing.Point(16, 58)
$panel.Size = New-Object System.Drawing.Size(670, 360)
$panel.AutoScroll = $true
$form.Controls.Add($panel)

$y = 8
$checkMap = @{}
foreach ($key in $options.Keys) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Location = New-Object System.Drawing.Point(8, $y)
    $cb.Size = New-Object System.Drawing.Size(630, 22)
    $cb.Text = $options[$key]
    $cb.Tag = $key
    $cb.Name = $key
    $panel.Controls.Add($cb)
    $checkMap[$key] = $cb
    $y += 26
}

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text = 'סמן הכל'
$btnAll.Location = New-Object System.Drawing.Point(16, 430)
$btnAll.Size = New-Object System.Drawing.Size(100, 28)
$btnAll.Add_Click({
    foreach ($c in $checkMap.Values) { $c.Checked = $true }
})
$form.Controls.Add($btnAll)

$btnNone = New-Object System.Windows.Forms.Button
$btnNone.Text = 'נקה סימון'
$btnNone.Location = New-Object System.Drawing.Point(126, 430)
$btnNone.Size = New-Object System.Drawing.Size(100, 28)
$btnNone.Add_Click({
    foreach ($c in $checkMap.Values) { $c.Checked = $false }
})
$form.Controls.Add($btnNone)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(16, 468)
$lblLog.Size = New-Object System.Drawing.Size(680, 20)
$logPathDisplay = $script:LogPath
$lblLog.Text = "יומן: יישמר אוטומטית ב-$logPathDisplay"
$form.Controls.Add($lblLog)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = 'התחל ניקוי'
$btnRun.Location = New-Object System.Drawing.Point(520, 500)
$btnRun.Size = New-Object System.Drawing.Size(160, 34)
$btnRun.Add_Click({
    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
})
$form.Controls.Add($btnRun)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'ביטול'
$btnCancel.Location = New-Object System.Drawing.Point(400, 500)
$btnCancel.Size = New-Object System.Drawing.Size(100, 34)
$btnCancel.Add_Click({
    $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Close()
})
$form.Controls.Add($btnCancel)

$dialogResult = $form.ShowDialog()

if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host 'בוטל.'
    exit 0
}

$selected = @{}
foreach ($kv in $checkMap.GetEnumerator()) {
    if ($kv.Value.Checked) { $selected[$kv.Key] = $true }
}

if ($selected.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show('לא נבחר שום סעיף.', 'ניקוי מערכת', 'OK', 'Information')
    exit 0
}

Write-CleanupLog '======== התחלת ניקוי ========'
Write-CleanupLog "מנהל: $(Test-IsAdmin)"
$profiles = @(Get-UserProfileFolders)
Write-CleanupLog ('פרופילים: ' + ($profiles -join '; '))

foreach ($k in $selected.Keys) {
    switch ($k) {
        'UserTemp'      { Clear-UserTempFolders -ProfilePaths $profiles }
        'WindowsTemp'   { Clear-WindowsTempFolder }
        'Prefetch'      { Clear-PrefetchFolder }
        'Thumbnails'    { Clear-ThumbnailCachePerUser -ProfilePaths $profiles }
        'Chrome'        { Clear-ChromeCachePerUser -ProfilePaths $profiles }
        'Edge'          { Clear-EdgeCachePerUser -ProfilePaths $profiles }
        'Firefox'       { Clear-FirefoxCachePerUser -ProfilePaths $profiles }
        'Teams'         { Clear-TeamsCachePerUser -ProfilePaths $profiles }
        'DeliveryOpt'   { Clear-DeliveryOptimizationCache }
        'WinUpdateDl'   { Clear-SoftwareDistributionDownload }
        'WER'           { Clear-WindowsErrorReportingCache }
        'RecycleBin'    { Clear-RecycleBinAllDrives }
        'DnsCache'      { Clear-DnsClientCache }
        'DismComponent' { Invoke-DismComponentCleanup }
    }
}

Write-CleanupLog '======== סיום ניקוי ========'
[System.Windows.Forms.MessageBox]::Show(
    "הניקוי הסתיים.`nיומן: $script:LogPath",
    'ניקוי מערכת',
    'OK',
    'Information'
)

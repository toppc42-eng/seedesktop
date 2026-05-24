/// Shared PowerShell command catalogue — used in My Devices and the
/// in-session Terminal command panel.
///
/// [cmd] is either a literal command or a template with `{PARAM_NAME}` tokens
/// matching [params] (QuickCommand-style).
///
/// [group] = top-level category (tree root), [label] = sub-topic under the group.
library ps_commands_catalogue;

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/desktop/pages/seedesktop_terminal_special_ps1.dart';

/// Separator for bilingual catalogue strings: `English | עברית`.
const String kPsBilingualSep = ' | ';

/// Picks left part (English) or right part (Hebrew) based on UI language.
String psPickLocalizedBilingualField(String s) {
  if (s.isEmpty) return s;
  final i = s.indexOf(kPsBilingualSep);
  if (i < 0) return s;
  final en = s.substring(0, i).trim();
  final he = s.substring(i + kPsBilingualSep.length).trim();
  try {
    if (bind.mainGetLocalOption(key: kCommConfKeyLang) == 'he') {
      return he.isNotEmpty ? he : en;
    }
  } catch (_) {}
  return en.isNotEmpty ? en : he;
}

bool _psBilingualHaystackContains(String raw, String qLower) {
  if (raw.toLowerCase().contains(qLower)) return true;
  final i = raw.indexOf(kPsBilingualSep);
  if (i < 0) return false;
  final a = raw.substring(0, i).toLowerCase();
  final b = raw.substring(i + kPsBilingualSep.length).toLowerCase();
  return a.contains(qLower) || b.contains(qLower);
}

class PsCmd {
  final String title;
  final String cmd;
  final String? hint;
  final List<String> params;
  /// When set, UI shows [translate] of this key instead of [title].
  final String? localeTitleKey;
  /// When set, UI shows [translate] of this key instead of [hint].
  final String? localeHintKey;

  const PsCmd(
    this.title,
    this.cmd, {
    this.hint,
    this.params = const [],
    this.localeTitleKey,
    this.localeHintKey,
  });
}

class PsSection {
  /// Top-level category (e.g. רשת, מערכת הפעלה).
  final String group;
  /// Sub-topic under [group] (e.g. אבחון מהיר).
  final String label;
  final List<PsCmd> cmds;
  final String? localeGroupKey;
  final String? localeLabelKey;

  const PsSection(
    this.group,
    this.label,
    this.cmds, {
    this.localeGroupKey,
    this.localeLabelKey,
  });
}

/// Localized label for catalogue UI (English UI → en.rs, Hebrew → he.rs).
String psCmdDisplayTitle(PsCmd c) {
  final k = c.localeTitleKey;
  if (k != null && k.isNotEmpty) return translate(k);
  return psPickLocalizedBilingualField(c.title);
}

String? psCmdDisplayHint(PsCmd c) {
  final k = c.localeHintKey;
  if (k != null && k.isNotEmpty) return translate(k);
  final h = c.hint;
  if (h == null) return null;
  return psPickLocalizedBilingualField(h);
}

String psSectionDisplayGroup(PsSection s) {
  final k = s.localeGroupKey;
  if (k != null && k.isNotEmpty) return translate(k);
  return psPickLocalizedBilingualField(s.group);
}

String psSectionDisplayLabel(PsSection s) {
  final k = s.localeLabelKey;
  if (k != null && k.isNotEmpty) return translate(k);
  return psPickLocalizedBilingualField(s.label);
}

/// One expandable group in the UI (all [sections] share the same [title] = group).
class PsCatalogGroup {
  final String title;
  final List<PsSection> sections;

  const PsCatalogGroup(this.title, this.sections);
}

/// Preserves first-seen order of [PsSection.group].
List<PsCatalogGroup> groupCatalogSections(List<PsSection> sections) {
  final order = <String>[];
  final map = <String, List<PsSection>>{};
  for (final s in sections) {
    if (!map.containsKey(s.group)) {
      map[s.group] = [];
      order.add(s.group);
    }
    map[s.group]!.add(s);
  }
  return [for (final g in order) PsCatalogGroup(g, map[g]!)];
}

/// Fills `{NAME}` from [values]. Empty values keep `{NAME}` for preview.
String resolvePsCommand(PsCmd c, Map<String, String> values) {
  var s = c.cmd;
  for (final p in c.params) {
    final v = values[p]?.trim() ?? '';
    s = s.replaceAll('{$p}', v.isNotEmpty ? v : '{$p}');
  }
  return s;
}

bool psCommandParamsSatisfied(PsCmd c, Map<String, String> values) {
  for (final p in c.params) {
    if ((values[p] ?? '').trim().isEmpty) return false;
  }
  return true;
}

typedef QuickCommand = PsCmd;

final psCatalogue = <PsSection>[
  // --- SeeDesktop — highest priority (titles via locale keys: en + he) ---
  PsSection(
    'SeeDesktop special',
    'System info & forensics',
    [
      PsCmd(
        'Ultimate system audit & forensics',
        kPsSeeDesktopUltimateAuditForensics,
        hint: 'Requires PowerShell; run as admin / SYSTEM recommended',
        localeTitleKey: 'ps-sd-cmd-ultimate-audit',
        localeHintKey: 'ps-sd-hint-ultimate-audit',
      ),
      PsCmd(
        'Service crashes (30 days)',
        kPsSeeDesktopServiceCrashForensics30d,
        hint: 'System log — Service Control Manager',
        localeTitleKey: 'ps-sd-cmd-service-crash',
        localeHintKey: 'ps-sd-hint-service-crash',
      ),
      PsCmd(
        'BSOD forensics (30 days)',
        kPsSeeDesktopBsodForensics30d,
        hint: 'Events 1001 / 41 and minidumps',
        localeTitleKey: 'ps-sd-cmd-bsod',
        localeHintKey: 'ps-sd-hint-bsod',
      ),
      PsCmd(
        'Silent application crashes (14 days)',
        kPsSeeDesktopSilentAppCrashes14d,
        hint: 'Application log, event ID 1000',
        localeTitleKey: 'ps-sd-cmd-app-crash',
        localeHintKey: 'ps-sd-hint-app-crash',
      ),
      PsCmd(
        'Failed logons — brute-force check (7 days)',
        kPsSeeDesktopFailedLogons7d,
        hint: 'Security log 4625; requires audit policy / rights',
        localeTitleKey: 'ps-sd-cmd-failed-logon',
        localeHintKey: 'ps-sd-hint-failed-logon',
      ),
      PsCmd(
        'Battery health',
        kPsSeeDesktopBatteryHealthCheck,
        hint: 'WMI battery classes; desktops show no battery',
        localeTitleKey: 'ps-sd-cmd-battery',
        localeHintKey: 'ps-sd-hint-battery',
      ),
    ],
    localeGroupKey: 'ps-sd-group-special',
    localeLabelKey: 'ps-sd-label-forensics',
  ),

  // --- Active Directory ---
  PsSection('Active Directory', 'Accounts & groups | חשבונות וקבוצות', [
    PsCmd(
        'Find expired passwords | בדיקת חשבונות פגי תוקף',
        'Search-ADAccount -PasswordExpired'),
    PsCmd('Find locked accounts | בדיקת חשבונות נעולים',
        'Search-ADAccount -LockedOut'),
    PsCmd(
      'List AD users (all) | רשימת משתמשי AD (כללי)',
      'Get-ADUser -Filter *',
      hint: 'Requires ActiveDirectory module | דורש מודול ActiveDirectory',
    ),
    PsCmd(
      'AD user — all properties | משתמש AD — כל המאפיינים',
      r'Get-ADUser {SAM} -Properties *',
      params: ['SAM'],
      hint: 'SamAccountName, e.g. user1 | SamAccountName, לדוגמה user1',
    ),
    PsCmd(
      'Create AD user | יצירת משתמש AD',
      r'New-ADUser -Name "{DISPLAY_NAME}" -SamAccountName {SAM} -AccountPassword (Read-Host -AsSecureString) -Enabled $true',
      params: ['DISPLAY_NAME', 'SAM'],
      hint: 'Password prompt will appear | יופיע חלון לסיסמה',
    ),
    PsCmd(
      'Enable AD account | הפעלת חשבון AD',
      'Enable-ADAccount {SAM}',
      params: ['SAM'],
    ),
    PsCmd(
      'Disable AD account | השבתת חשבון AD',
      'Disable-ADAccount {SAM}',
      params: ['SAM'],
    ),
    PsCmd(
      'List AD groups | רשימת קבוצות AD',
      'Get-ADGroup -Filter *',
    ),
    PsCmd(
      'Add user to group | הוספת משתמש לקבוצה',
      r"Add-ADGroupMember -Identity '{GROUP}' -Members '{USER}'",
      params: ['GROUP', 'USER'],
    ),
    PsCmd(
      'Remove user from group | הסרת משתמש מקבוצה',
      "Remove-ADGroupMember -Identity '{GROUP}' -Members '{USER}' -Confirm:\$false",
      params: ['GROUP', 'USER'],
    ),
    PsCmd(
      'Unlock account | שחרור חשבון',
      r'Unlock-ADaccount -identity "{USERNAME}"',
      params: ['USERNAME'],
      hint: 'Username in AD | שם המשתמש ב-AD',
    ),
    PsCmd(
      'Unlock multiple (grid) | שחרור חשבונות מרובים',
      'search-adaccount -lockedout | out-gridview -passthru | unlock-adaccount',
    ),
    PsCmd(
      'Reset password | איפוס סיסמא',
      r'Set-ADAccountPassword {USERNAME} -NewPassword (Read-Host "Enter the new password" -AsSecureString) -Reset',
      params: ['USERNAME'],
      hint:
          'Remove -Reset to skip “change at next logon” | הסר -Reset אם לא רוצים כפיית שינוי סיסמה ב-login הבא',
    ),
    PsCmd('Sync AD to Azure AD | סנכרון AD עם Azure AD',
        'Start-ADSyncSyncCycle -PolicyType Delta'),
    PsCmd(
      'Add two users to AD group | הוספת משתמש לקבוצת AD (שני משתמשים)',
      "Add-ADGroupMember -Identity '{GROUPNAME}' -Members '{USERNAME1}','{USERNAME2}'",
      params: ['GROUPNAME', 'USERNAME1', 'USERNAME2'],
      hint: 'Names as shown in AD | שמות כפי שמופיעים ב-AD',
    ),
  ]),

  // --- תחזוקה וניקוי ---
  PsSection('Maintenance | תחזוקה וניקוי', 'Disk & cache cleanup | ניקוי דיסק ומטמון', [
    PsCmd(
      'Clear temp folders | ניקוי קבצים זמניים (Temp)',
      r'Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -Path "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue',
    ),
    PsCmd(
      'Clear Windows Update cache | ניקוי מטמון עדכוני Windows',
      r'Stop-Service wuauserv; Remove-Item -Path "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue; Start-Service wuauserv',
    ),
    PsCmd(
      'Empty Recycle Bin | ריקון סל המיחזור',
      'Clear-RecycleBin -Force -ErrorAction SilentlyContinue',
    ),
    PsCmd(
      'Full cleanup (combined) | ניקוי מערכת מקיף (הכל ביחד)',
      r'Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -Path "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue; Stop-Service wuauserv; Remove-Item -Path "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue; Start-Service wuauserv',
    ),
  ]),

  PsSection(
      'Maintenance | תחזוקה וניקוי',
      'SFC, DISM & disk repair | SFC, DISM ותיקון דיסק',
      [
        PsCmd(
          'SFC — scan & repair system files | SFC — סריקה ותיקון קבצי מערכת',
          r'Start-Process -FilePath "$env:SystemRoot\System32\sfc.exe" -ArgumentList "/scannow" -Wait -NoNewWindow',
          hint:
              'Elevated PowerShell/CMD. Can take many minutes. | הרצה כמנהל; עלול לארוך זמן רב.',
        ),
        PsCmd(
          'DISM — scan Windows image health | DISM — בדיקת תקינות תמונת Windows',
          r'Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" -ArgumentList "/Online","/Cleanup-Image","/ScanHealth" -Wait -NoNewWindow',
          hint:
              'Elevated. Lighter check before RestoreHealth. | הרצה כמנהל; בדיקה מהירה יחסית.',
        ),
        PsCmd(
          'DISM — restore Windows image health | DISM — שחזור תמונת Windows (RestoreHealth)',
          r'Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" -ArgumentList "/Online","/Cleanup-Image","/RestoreHealth" -Wait -NoNewWindow',
          hint:
              'Elevated. Run if SFC cannot repair; may download files. Often run SFC again after. | הרצה כמנהל; אם SFC נכשל; אחרי זה מומלץ להריץ שוב SFC.',
        ),
        PsCmd(
          'Optimize-Volume — TRIM (SSD) | אופטימיזציה — TRIM ל-SSD',
          r'Optimize-Volume -DriveLetter {DRIVE} -ReTrim -Verbose',
          params: ['DRIVE'],
          hint:
              'Drive letter only (e.g. C). Use on SSD. | אות כונן בלבד (למשל C); ל-SSD.',
        ),
        PsCmd(
          'Optimize-Volume — defrag (HDD) | אופטימיזציה — defrag ל-HDD',
          r'Optimize-Volume -DriveLetter {DRIVE} -Defrag -Verbose',
          params: ['DRIVE'],
          hint:
              'Drive letter only. Classic HDD / spinning rust. | אות כונן; לדיסקים מכניים.',
        ),
        PsCmd(
          'Optimize-Volume — auto (TRIM or defrag) | אופטימיזציה — אוטומטי לפי סוג דיסק',
          r'Optimize-Volume -DriveLetter {DRIVE} -Verbose',
          params: ['DRIVE'],
          hint:
              'Windows picks TRIM vs defrag. | המערכת בוחרת TRIM או defrag.',
        ),
        PsCmd(
          'CHKDSK — full scan /R and dismount /X | CHKDSK — סריקה מלאה /R וניתוק /X',
          r'chkdsk {DRIVE}: /r /x',
          params: ['DRIVE'],
          hint:
              'Letter only (C). On C: run in elevated CMD and confirm schedule at reboot; long run. | אות בלבד; על C: לרוב דורש אתחול ואישור; ארוך.',
        ),
        PsCmd(
          'CHKDSK — online scan (lighter) | CHKDSK — סריקה מקוונת (קלה יותר)',
          r'chkdsk {DRIVE}: /scan',
          params: ['DRIVE'],
          hint:
              'Windows 8+. Less invasive than /R. | פחות אגרסיבי מ-/R.',
        ),
      ]),

  // --- רשת ---
  PsSection('Network | רשת', 'Quick diagnostics | אבחון מהיר', [
    PsCmd(
      'IP configuration (table) | תצורת IP (טבלה)',
      'Get-NetIPConfiguration | Format-Table -AutoSize',
    ),
    PsCmd('ipconfig /all | ipconfig מלא', 'ipconfig /all'),
    PsCmd(
      'Internet connectivity check | בדיקת קישוריות לאינטרנט',
      'Test-NetConnection -ComputerName 8.8.8.8 -InformationLevel Quiet',
    ),
    PsCmd(
      'Ping host | בדיקת קישוריות לכתובת',
      'Test-Connection -ComputerName {HOST} -Count 4',
      params: ['HOST'],
      hint: 'Hostname or IP | שם או IP',
    ),
    PsCmd(
      'DNS lookup test | בדיקת DNS',
      'Resolve-DnsName google.com',
    ),
    PsCmd(
      'Traceroute | מעקב נתיב (TraceRoute)',
      'Test-NetConnection -ComputerName google.com -TraceRoute',
      hint: 'May take a few seconds | עלול לקחת כמה שניות',
    ),
    PsCmd(
      'Default gateway routes | שער ברירת מחדל (נתיבים)',
      'Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Format-Table -AutoSize',
    ),
    PsCmd(
      'Connections & ports (netstat) | חיבורים ופורטים (netstat)',
      'netstat -ano',
    ),
    PsCmd(
      'Network adapters | כרטיסי רשת',
      'Get-NetAdapter | Format-Table Name, Status, LinkSpeed, MacAddress -AutoSize',
    ),
    PsCmd(
      'IP addresses per interface | כתובות IP (ממשקים)',
      'Get-NetIPAddress | Format-Table InterfaceAlias, AddressFamily, IPAddress, PrefixLength -AutoSize',
    ),
    PsCmd(
      'DNS servers per interface | שרתי DNS (ממשקים)',
      'Get-DnsClientServerAddress | Format-Table -AutoSize',
    ),
    PsCmd(
      'WinHTTP proxy | פרוקסי WinHTTP',
      'netsh winhttp show proxy',
    ),
    PsCmd('Ping by name | בדיקת קישוריות (שם)',
        'Test-Connection google.com -Count 4'),
  ]),
  PsSection('Network | רשת', 'Quick fixes | תיקון מהיר', [
    PsCmd(
      'Release & renew DHCP | שחרור וחידוש DHCP',
      'ipconfig /release; ipconfig /renew',
      hint: 'Brief network drop | ניתוק קצר מהרשת',
    ),
    PsCmd(
      'Flush DNS cache (ipconfig) | ניקוי מטמון DNS (מקומי)',
      'ipconfig /flushdns',
    ),
    PsCmd(
      'Register DNS | רישום מחדש ב-DNS',
      'ipconfig /registerdns',
    ),
    PsCmd(
      'Clear DNS cache (Cmdlet) | ניקוי מטמון DNS (Cmdlet)',
      'Clear-DnsClientCache',
    ),
    PsCmd(
      'Restart all network adapters | הפעלה מחדש לכל כרטיסי הרשת',
      r'Get-NetAdapter | Restart-NetAdapter -Confirm:$false',
      hint: '⚠️ Temporary disconnect on all interfaces | ⚠️ ניתוק זמני מכל הממשקים',
    ),
    PsCmd(
      'Reset WinHTTP proxy | איפוס פרוקסי WinHTTP',
      'netsh winhttp reset proxy',
    ),
    PsCmd(
      'Test domain secure channel | בדיקת Domain Trust',
      'Test-ComputerSecureChannel',
    ),
    PsCmd(
      'Repair domain secure channel | תיקון Domain Trust',
      'Test-ComputerSecureChannel -Repair',
    ),
    PsCmd(
      'Test outbound port | בדיקת פורט יוצא',
      'Test-NetConnection -ComputerName google.com -Port {PORT}',
      params: ['PORT'],
      hint: 'e.g. 443 | לדוגמה 443',
    ),
  ]),
  PsSection('Network | רשת', 'Deep reset (careful) | איפוס מעמיק (זהירות)', [
    PsCmd(
      'Reset Winsock | איפוס Winsock',
      'netsh winsock reset',
      hint: '⚠️ Reboot may be required | ⚠️ לעיתים נדרש Restart למחשב',
    ),
    PsCmd(
      'Reset TCP/IP stack | איפוס מחסנית TCP/IP',
      'netsh int ip reset',
      hint:
          '⚠️ Reboot may be required; custom settings may be lost | ⚠️ לעיתים נדרש Restart; ייתכן אובדן הגדרות רשת מותאמות',
    ),
    PsCmd(
      'Reset TCP/IP + log file | איפוס TCP/IP + לוג',
      r'netsh int ip reset "$env:TEMP\ip_reset.log"',
      hint: '⚠️ Reboot recommended after run | ⚠️ Restart מומלץ אחרי ההרצה',
    ),
    PsCmd(
      'Clear ARP table | ניקוי טבלת ARP',
      'arp -d *',
      hint: 'Run as admin / SYSTEM | דורש הרצה כמנהל / SYSTEM',
    ),
  ]),
  PsSection('Network | רשת', 'Wi‑Fi | Wi‑Fi', [
    PsCmd(
      'Wi‑Fi interface status | מצב ממשק Wi‑Fi',
      'netsh wlan show interfaces',
    ),
    PsCmd(
      'Saved Wi‑Fi profiles | פרופילי Wi‑Fi שמורים',
      'netsh wlan show profiles',
    ),
    PsCmd(
      'Delete Wi‑Fi profile | מחיקת פרופיל Wi‑Fi',
      'netsh wlan delete profile name="{SSID}"',
      params: ['SSID'],
      hint: 'SSID as shown in profiles | שם הרשת כפי שמופיע ב-profiles',
    ),
  ]),
  PsSection('Network | רשת', 'Firewall | חומת אש', [
    PsCmd(
      'Firewall rules (first 40) | חוקי Firewall (40 ראשונים)',
      'Get-NetFirewallRule | Select-Object -First 40 DisplayName, Enabled, Direction, Action | Format-Table -AutoSize',
      hint: 'Full list is very long | הרשימה המלאה ארוכה מאוד',
    ),
  ]),

  // --- אבטחה ---
  PsSection('Security & sharing | אבטחה ושיתוף', 'SMB & LSA | SMB ו-LSA', [
    PsCmd(
      'Allow insecure guest auth (SMB) | אפשור שיתוף רשת ללא סיסמה (Guest Auth)',
      r'Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -Name "AllowInsecureGuestAuth" -Value 1 -Type DWord',
    ),
    PsCmd(
      'Block insecure guest auth (SMB) | חסימת שיתוף רשת ללא סיסמה',
      r'Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -Name "AllowInsecureGuestAuth" -Value 0 -Type DWord',
    ),
    PsCmd(
      'Allow anonymous access (RestrictAnonymous=0) | אפשור גישה אנונימית (RestrictAnonymous = 0)',
      r'Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RestrictAnonymous" -Value 0 -Type DWord',
    ),
    PsCmd(
      'Restrict anonymous (RestrictAnonymous=1) | חסימת גישה אנונימית (RestrictAnonymous = 1)',
      r'Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RestrictAnonymous" -Value 1 -Type DWord',
    ),
  ]),

  // --- תוכנה ---
  PsSection('Software | תוכנה', 'Install & remove | התקנה והסרה', [
    PsCmd(
      'Silent uninstall (MSI/WMI) | הסרת תוכנה שקטה (MSI/WMI)',
      "Get-WmiObject -Class Win32_Product -Filter \"Name LIKE '%{APP_NAME}%'\" | Invoke-WmiMethod -Name Uninstall",
      params: ['APP_NAME'],
      hint:
          'Part of display name (e.g. TeamViewer, Chrome) | חלק משם התצוגה (לדוגמה: TeamViewer, Chrome)',
    ),
    PsCmd(
      'Uninstall TeamViewer | הסרת TeamViewer',
      "Get-WmiObject -Class Win32_Product -Filter \"Vendor LIKE 'TeamViewer' \" | Foreach { (\$_).uninstall() }",
    ),
    PsCmd(
      'Installed programs (32-bit) | רשימת תוכנות 32bit',
      r"Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate",
    ),
    PsCmd(
      'Installed programs (64-bit) | רשימת תוכנות 64bit',
      r'Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate | Where-Object Displayname -notlike ""',
    ),
    PsCmd(
      'All installed programs (32+64) | כל התוכנות (32+64bit)',
      r'$sl=@(); $sl+=Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* | Select-Object DisplayName,DisplayVersion,Publisher,InstallDate; $sl+=Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | Select-Object DisplayName,DisplayVersion,Publisher,InstallDate; $sl | Where-Object DisplayName -notlike "" | Sort-Object DisplayName',
    ),
    PsCmd('AppX packages (all users) | AppX Packages (כל המשתמשים)',
        'Get-AppxPackage -AllUsers'),
  ]),
  PsSection('Software | תוכנה', 'Packages & Server | חבילות ושרת', [
    PsCmd(
      'Installed packages (Get-Package) | חבילות מותקנות (Get-Package)',
      'Get-Package',
    ),
    PsCmd(
      'Windows Server features | פיצ׳רים — Windows Server',
      'Get-WindowsFeature',
      hint: 'Windows Server with roles only | רק על Windows Server עם הרול המתאים',
    ),
    PsCmd(
      'Install Server feature | התקנת פיצ׳ר Server',
      'Install-WindowsFeature -Name {FEATURE} -IncludeManagementTools',
      params: ['FEATURE'],
      hint: 'e.g. Web-Server | לדוגמה: Web-Server',
    ),
  ]),

  // --- מערכת הפעלה ---
  PsSection('Operating system | מערכת הפעלה', 'Info & power | מידע והפעלה', [
    PsCmd('List local users | רשימת משתמשים מקומיים', 'Get-LocalUser'),
    PsCmd('Full computer info | מידע מלא על המחשב', 'Get-ComputerInfo'),
    PsCmd(
      'Summary computer info | מידע תמציתי על המחשב',
      'Get-ComputerInfo CsName,WindowsProductName,CsDomain,CsProcessors,LogonServer,OsVersion,BiosReleaseDate',
    ),
    PsCmd(
      'Download file from URL | הורדת קובץ מ-URL',
      r"Invoke-WebRequest '{URL}' -OutFile '{OUTFILE}'",
      params: ['URL', 'OUTFILE'],
      hint: r'Full URL and path (e.g. C:\temp\file.exe) | URL מלא ונתיב יעד (למשל C:\temp\file.exe)',
    ),
    PsCmd('Empty Recycle Bin (C:) | ריקון Recycle Bin (כונן C)',
        'Clear-RecycleBin -force -driveletter C'),
    PsCmd('Printer info | מידע על מדפסות', 'Get-Printer'),
    PsCmd(
      'Printers & ports (USB/LAN) | רשימת מדפסות וסוג חיבור (USB/LAN)',
      r'Get-Printer | Select-Object Name, PortName, PrinterStatus | Format-Table -AutoSize',
    ),
    PsCmd(
      'Rename computer & reboot | שינוי שם מחשב והפעלה מחדש',
      'Rename-Computer -newname {NEWNAME} -Restart',
      params: ['NEWNAME'],
    ),
    PsCmd('Restart Print Spooler | הפעלה מחדש של Print Spooler',
        'Restart-Service -Name Spooler'),
    PsCmd('Restart computer | אתחול מחשב', 'Restart-Computer'),
    PsCmd('Shut down computer | כיבוי מחשב', 'Stop-Computer'),
    PsCmd('Force restart | אתחול מיידי מכריח', 'Restart-Computer -Force'),
    PsCmd(
      'Find processes by name | חיפוש תהליכים לפי שם',
      r"get-process | where-object name -like '*{WORD}*'",
      params: ['WORD'],
    ),
    PsCmd(
      'Stop processes by name | עצירת תהליכים לפי שם',
      r"get-process | where-object name -like '*{WORD}*' | stop-process",
      params: ['WORD'],
      hint:
          '⚠️ Run search without stop-process first | ⚠️ הפעל קודם חיפוש בלי stop-process',
    ),
    PsCmd(
      'Paths longer than 220 chars | קבצים עם נתיב > 220 תווים',
      '(get-Childitem -Recurse).fullname | Where-Object length -gt 220',
      hint: "After cd into folder | לאחר 'cd' לתיקייה",
    ),
  ]),
  PsSection('Operating system | מערכת הפעלה', 'Processes & services | תהליכים ושירותים', [
    PsCmd(
      'List all processes | רשימת כל התהליכים',
      'Get-Process',
    ),
    PsCmd(
      'Stop process by name | עצירת תהליך לפי שם',
      'Stop-Process -Name {NAME} -ErrorAction SilentlyContinue',
      params: ['NAME'],
      hint: 'e.g. notepad | לדוגמה: notepad',
    ),
    PsCmd(
      'List services | רשימת שירותים',
      'Get-Service',
    ),
    PsCmd(
      'Restart service | הפעלה מחדש של שירות',
      'Restart-Service -Name {SERVICE_NAME} -ErrorAction SilentlyContinue',
      params: ['SERVICE_NAME'],
      hint: 'e.g. Spooler | לדוגמה: Spooler',
    ),
  ]),
  PsSection('Operating system | מערכת הפעלה', 'Advanced | ניהול מתקדם', [
    PsCmd(
      'Remove built-in Windows app | הסרת אפליקציית Windows מובנית',
      r'Get-AppxPackage *{APP_NAME}* | Remove-AppxPackage',
      params: ['APP_NAME'],
      hint: 'e.g. xbox, zune | לדוגמה: xbox, zune',
    ),
    PsCmd(
      'Kill process by name | חיסול תהליך לפי שם',
      r'Get-Process {PROCESS_NAME} -ErrorAction SilentlyContinue | Stop-Process -Force',
      params: ['PROCESS_NAME'],
      hint: 'Name from Get-Process | שם התהליך כפי שמופיע ב-Get-Process',
    ),
    PsCmd(
      'Top 10 largest folders on drive | מציאת 10 התיקיות הגדולות בכונן',
      r'Get-ChildItem {DRIVE_LETTER}:\ -Directory -ErrorAction SilentlyContinue | Select-Object Name, @{Name="Size(MB)";Expression={(Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB}} | Sort-Object -Property "Size(MB)" -Descending | Select-Object -First 10',
      params: ['DRIVE_LETTER'],
      hint: 'Drive letter only, e.g. C or D | אות כונן בלבד, לדוגמה: C או D',
    ),
    PsCmd(
      'Process owning local port | איתור תהליך שתופס פורט',
      r'Get-Process -Id (Get-NetTCPConnection -LocalPort {PORT_NUMBER}).OwningProcess',
      params: ['PORT_NUMBER'],
      hint: 'Local port number | מספר פורט מקומי',
    ),
  ]),

  // --- קבצים ---
  PsSection('Files & folders | קבצים ותיקיות', 'File management | ניהול קבצים', [
    PsCmd(
      'List folder (like dir) | הצגת תוכן תיקייה (כמו dir)',
      'Get-ChildItem',
      hint: 'Run from target folder (cd) | הרץ מתוך התיקייה הרצויה (cd)',
    ),
    PsCmd(
      'Recursive listing | חיפוש רקורסיבי בתיקייה',
      'Get-ChildItem -Recurse',
      hint: 'Prefer after cd to root | ברצוי אחרי cd לתיקיית שורש',
    ),
    PsCmd(
      'Copy file or folder | העתקת קובץ או תיקייה',
      r"Copy-Item '{SOURCE}' '{DEST}'",
      params: ['SOURCE', 'DEST'],
      hint: r'Full paths, e.g. C:\Src\a.txt | נתיבים מלאים, לדוגמה C:\Src\a.txt',
    ),
    PsCmd(
      'Move / rename | העברה / שינוי שם',
      r"Move-Item '{SOURCE}' '{DEST}'",
      params: ['SOURCE', 'DEST'],
    ),
    PsCmd(
      'Delete file or folder | מחיקת קובץ או תיקייה',
      r"Remove-Item '{PATH}' -Recurse -Force -ErrorAction SilentlyContinue",
      params: ['PATH'],
      hint: '⚠️ Permanent delete | ⚠️ מחיקה קבועה',
    ),
    PsCmd(
      'Create empty file | יצירת קובץ ריק',
      r"New-Item -ItemType File -Path '{PATH}' -Force",
      params: ['PATH'],
    ),
    PsCmd(
      'Create folder | יצירת תיקייה',
      r"New-Item -ItemType Directory -Path '{PATH}' -Force",
      params: ['PATH'],
    ),
  ]),

  // --- יומנים ---
  PsSection('Event logs | יומני אירועים', 'System / Application | יומן מערכת ויישום', [
    PsCmd(
      'Unexpected shutdown reason | סיבת כיבוי בלתי צפוי',
      'Get-EventLog -LogName system -Source user32 | Select-Object TimeGenerated, Message | Sort-Object message',
    ),
    PsCmd(
      'System log — last 100 | 100 אירועים אחרונים ב-System Log',
      'Get-EventLog -LogName system -Newest 100',
    ),
    PsCmd(
      'Application log — last 50 | 50 אירועים אחרונים — Application',
      'Get-EventLog -LogName Application -Newest 50',
    ),
  ]),

  // --- הרשאות ---
  PsSection('Permissions & users | הרשאות ומשתמשים', 'ACL & local user | ACL ומשתמש מקומי', [
    PsCmd(
      'NTFS ACL | בדיקת הרשאות NTFS',
      r"Get-Acl '{PATH}' | Format-List",
      params: ['PATH'],
    ),
    PsCmd(
      'Create local user | יצירת משתמש מקומי',
      r'New-LocalUser -Name {USERNAME} -Password (Read-Host -AsSecureString)',
      params: ['USERNAME'],
      hint: 'Password prompt | יופיע חלון להזנת סיסמה',
    ),
  ]),

  // --- Registry ---
  PsSection('Registry', 'Read & write | קריאה וכתיבה', [
    PsCmd(
      'Read registry value | קריאת ערך מהרישום',
      r'Get-ItemProperty "{PATH}"',
      params: ['PATH'],
      hint:
          r'e.g. HKLM:\Software\Microsoft\Windows NT\CurrentVersion | לדוגמה HKLM:\Software\Microsoft\Windows NT\CurrentVersion',
    ),
    PsCmd(
      'Set registry value | הגדרת ערך ברישום',
      r'Set-ItemProperty -Path "{PATH}" -Name {NAME} -Value "{VALUE}"',
      params: ['PATH', 'NAME', 'VALUE'],
      hint: '⚠️ Backup before change | ⚠️ גבו לפני שינוי',
    ),
  ]),

  // --- אוטומציה ---
  PsSection('Automation & help | אוטומציה ועזרה', 'Tools | כלים', [
    PsCmd(
      'Import CSV | ייבוא CSV',
      r"Import-Csv '{PATH}'",
      params: ['PATH'],
    ),
    PsCmd(
      'Export to CSV (example) | ייצוא ל-CSV (דוגמה)',
      r"Get-Process | Select-Object Name, CPU | Export-Csv -Path '{PATH}' -NoTypeInformation -Encoding UTF8",
      params: ['PATH'],
    ),
    PsCmd(
      'List available commands | רשימת פקודות זמינות',
      'Get-Command',
    ),
    PsCmd(
      'Full help for cmdlet | עזרה מלאה לפקודה',
      'Get-Help {CMDLET} -Full',
      params: ['CMDLET'],
      hint: 'e.g. Get-Process | לדוגמה: Get-Process',
    ),
  ]),

  // --- עיצוב פלט ---
  PsSection('Output formatting | עיצוב פלט', 'Modifiers (append) | Modifiers (הוספה לסוף פקודה)', [
    PsCmd('Copy output to clipboard | העתקת פלט ללוח', '| Clip',
        hint: 'Append to command | בסוף פקודה'),
    PsCmd('Format as list | הצגה כ-List', '| Format-List',
        hint: 'Append to command | בסוף פקודה'),
    PsCmd('Format as table | הצגה כ-Table', '| Format-Table',
        hint: 'Append to command | בסוף פקודה'),
    PsCmd('Save to file | שמירה לקובץ', r'| Out-File C:\temp\output.txt',
        hint: 'Append to command | בסוף פקודה'),
    PsCmd('Out-GridView (filterable) | רשימה ניתנת לסינון', '| Out-Gridview',
        hint: 'Append to command | בסוף פקודה'),
  ]),
];

/// Lowercase [q] (from [query].toLowerCase()). Used by catalogue search and
/// the editable global PS catalog store.
bool psCatalogItemMatchesQuery(PsSection s, PsCmd c, String qLower) {
  return _psBilingualHaystackContains(c.title, qLower) ||
      psCmdDisplayTitle(c).toLowerCase().contains(qLower) ||
      c.cmd.toLowerCase().contains(qLower) ||
      _psBilingualHaystackContains(s.group, qLower) ||
      _psBilingualHaystackContains(s.label, qLower) ||
      psSectionDisplayGroup(s).toLowerCase().contains(qLower) ||
      psSectionDisplayLabel(s).toLowerCase().contains(qLower) ||
      (c.hint != null && _psBilingualHaystackContains(c.hint!, qLower)) ||
      (psCmdDisplayHint(c)?.toLowerCase().contains(qLower) ?? false) ||
      c.params.any((p) => p.toLowerCase().contains(qLower));
}

List<PsSection> filterPsSections(String query, {List<PsSection>? catalogue}) {
  final list = catalogue ?? psCatalogue;
  if (query.trim().isEmpty) return list;
  final q = query.toLowerCase();
  return list
      .map((s) {
        final filteredCmds =
            s.cmds.where((c) => psCatalogItemMatchesQuery(s, c, q)).toList();
        return PsSection(
          s.group,
          s.label,
          filteredCmds,
          localeGroupKey: s.localeGroupKey,
          localeLabelKey: s.localeLabelKey,
        );
      })
      .where((s) => s.cmds.isNotEmpty)
      .toList();
}

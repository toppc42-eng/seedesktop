//! Local hardware snapshot for the desktop sidebar (temperature, fan, disks, CPU id).
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Single suggested remediation shown in the Flutter hardware panel.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct ActionItem {
    pub action_id: String,
    pub button_label: String,
    pub command: String,
    pub severity: String,
}

/// Physical disk line from `hw_helper` (`disk_model` / `disk_type` in JSON).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct DiskInfo {
    #[serde(rename = "disk_model", alias = "model")]
    pub model: String,
    #[serde(rename = "disk_type", alias = "type")]
    pub disk_type: String,
}

/// Per-core temperature reading from LibreHardwareMonitor.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct CoreTemp {
    pub name: String,
    pub temp_c: f64,
}

/// Single fan reading from LibreHardwareMonitor.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct FanReading {
    pub name: String,
    pub rpm: i64,
}

/// Serializable `hw_health` payload (agent heartbeat + Flutter sidebar).
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct HwHealth {
    pub cpu_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_processor_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ram_gb: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ram_slots_used: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ram_slots_total: Option<i32>,
    #[serde(default = "unknown_string")]
    pub ram_speed: String,
    #[serde(default = "unknown_string")]
    pub ram_type: String,
    #[serde(default = "unknown_string")]
    pub ram_slots_usage: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub disk_info: Vec<DiskInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_temp_c: Option<f64>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub cpu_cores_temp_c: Vec<CoreTemp>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub fans: Vec<FanReading>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fan_rpm: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fan_name: Option<String>,
    pub disks: Vec<Value>,
    pub temp_status: String,
    pub fan_status: String,
    pub recommended_actions: Vec<ActionItem>,
}

fn unknown_string() -> String {
    "Unknown".to_string()
}

fn normalize_disk_field(s: &str) -> String {
    let t = s.trim();
    if t.is_empty() {
        unknown_string()
    } else {
        t.to_string()
    }
}

fn opt_str_or_unknown(o: &Option<String>) -> String {
    o.as_ref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .unwrap_or_else(unknown_string)
}

fn normalize_windows_drive_id(id: &str) -> String {
    id.trim()
        .trim_end_matches('\\')
        .trim_end_matches('/')
        .to_ascii_uppercase()
}

/// Returns free space % for the Windows C: volume when present in [disks] JSON entries.
fn read_c_drive_free_pct(disks: &[Value]) -> Option<f64> {
    for d in disks {
        let id = d.get("id")?.as_str()?;
        if normalize_windows_drive_id(id) != "C:" {
            continue;
        }
        return Some(d.get("free_pct")?.as_f64()?);
    }
    None
}

fn recommended_actions_low_c_drive(free_pct: f64) -> Vec<ActionItem> {
    if free_pct >= 20.0 {
        return Vec::new();
    }
    vec![
        ActionItem {
            action_id: "CLEAN_C".into(),
            button_label: "הרץ ניקוי דיסק (C:)".into(),
            command: "cleanmgr.exe /d c: /VERYLOWDISK".into(),
            severity: "High".into(),
        },
        ActionItem {
            action_id: "ANALYZE_C".into(),
            button_label: "זהה תיקיות כבדות".into(),
            command: "explorer.exe".into(),
            severity: "Medium".into(),
        },
    ]
}

/// Telemetry / API alias for [snapshot] (agent heartbeat `hw_health` payload).
#[inline]
pub fn get_hardware_health() -> Value {
    snapshot()
}

#[cfg(any(target_os = "android", target_os = "ios"))]
pub fn snapshot() -> Value {
    json!({})
}

#[cfg(all(
    not(any(target_os = "android", target_os = "ios")),
    target_os = "windows"
))]
pub fn snapshot() -> Value {
    windows_collect()
}

#[cfg(all(
    not(any(target_os = "android", target_os = "ios")),
    not(target_os = "windows")
))]
pub fn snapshot() -> Value {
    non_windows_collect()
}

#[cfg(all(
    not(any(target_os = "android", target_os = "ios")),
    not(target_os = "windows")
))]
fn non_windows_collect() -> Value {
    use hbb_common::sysinfo::System;
    let mut sys = System::new();
    sys.refresh_cpu();
    sys.refresh_memory();
    let cpu_name = sys
        .cpus()
        .first()
        .map(|c| c.brand().trim().to_string())
        .unwrap_or_default();

    let disks = disk_entries_from_sysinfo();
    let recommended_actions = read_c_drive_free_pct(&disks)
        .map(recommended_actions_low_c_drive)
        .unwrap_or_default();
    let hw = HwHealth {
        cpu_name,
        cpu_processor_id: None,
        cpu_model: None,
        ram_gb: None,
        ram_slots_used: None,
        ram_slots_total: None,
        ram_speed: unknown_string(),
        ram_type: unknown_string(),
        ram_slots_usage: unknown_string(),
        disk_info: Vec::new(),
        cpu_temp_c: None,
        cpu_cores_temp_c: Vec::new(),
        fans: Vec::new(),
        fan_rpm: None,
        fan_name: None,
        disks,
        temp_status: "unknown".into(),
        fan_status: "unknown".into(),
        recommended_actions,
    };
    serde_json::to_value(&hw).unwrap_or_else(|_| json!({}))
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn disk_entries_from_sysinfo() -> Vec<Value> {
    use hbb_common::sysinfo::Disks;
    let disks = Disks::new_with_refreshed_list();
    let mut out = Vec::new();
    for d in disks.list() {
        let total = d.total_space();
        if total == 0 {
            continue;
        }
        let free = d.available_space();
        let used = total.saturating_sub(free);
        let used_pct = (used as f64 / total as f64) * 100.0;
        let free_pct = (free as f64 / total as f64) * 100.0;
        let mount = d.mount_point().to_string_lossy().to_string();
        out.push(json!({
            "id": mount,
            "label": "",
            "total_gb": (total as f64) / (1024.0 * 1024.0 * 1024.0),
            "free_gb": (free as f64) / (1024.0 * 1024.0 * 1024.0),
            "used_pct": used_pct,
            "free_pct": free_pct,
            "health": disk_health(free_pct),
            "disk_model": "Unknown",
            "disk_type": "Unknown",
        }));
    }
    out
}

fn disk_health(free_pct: f64) -> &'static str {
    if free_pct > 20.0 {
        "green"
    } else if free_pct >= 10.0 {
        "yellow"
    } else {
        "red"
    }
}

fn temp_health(temp_c: f64) -> &'static str {
    if temp_c < 70.0 {
        "green"
    } else if temp_c <= 85.0 {
        "yellow"
    } else {
        "red"
    }
}

fn fan_health(rpm: u64) -> &'static str {
    if rpm >= 800 {
        "green"
    } else if rpm >= 400 {
        "yellow"
    } else {
        "red"
    }
}

/// Per-volume physical disk mapping from `hw_helper.exe` (WMI associators).
#[cfg(target_os = "windows")]
#[derive(Clone, Deserialize)]
struct LogicalDiskSpecRow {
    id: String,
    #[serde(default)]
    disk_model: String,
    #[serde(default)]
    disk_type: String,
}

/// JSON line from `hw_helper.exe` (LibreHardwareMonitor + WMI specs).
#[cfg(target_os = "windows")]
#[derive(Deserialize)]
struct LhmHelperOut {
    cpu_temp_c: Option<f64>,
    fan_rpm: Option<u64>,
    cpu_model: Option<String>,
    ram_gb: Option<f64>,
    ram_slots_used: Option<i32>,
    ram_slots_total: Option<i32>,
    ram_speed: Option<String>,
    ram_type: Option<String>,
    ram_slots_usage: Option<String>,
    #[serde(default)]
    disk_info: Vec<DiskInfo>,
    #[serde(default)]
    logical_disk_specs: Vec<LogicalDiskSpecRow>,
    #[serde(default)]
    cpu_cores_temp_c: Vec<CoreTemp>,
    #[serde(default)]
    fans: Vec<FanReading>,
}

#[cfg(target_os = "windows")]
fn resolve_hw_helper_exe(exe_dir: &std::path::Path) -> Option<std::path::PathBuf> {
    let candidates = [
        exe_dir.join("hw_helper/bin/Release/net10.0-windows/hw_helper.exe"),
        exe_dir.join("hw_helper/bin/Release/net8.0-windows/hw_helper.exe"),
        exe_dir.join("hw_helper.exe"),
    ];
    for p in &candidates {
        if p.is_file() {
            return Some(p.clone());
        }
    }
    None
}

/// Parsed `hw_helper.exe` stdout. On failure, temperature/fan fall back to `0` (legacy behavior).
#[cfg(target_os = "windows")]
#[derive(Clone)]
struct HwHelperTelemetry {
    cpu_temp_c: Option<f64>,
    fan_rpm: Option<u64>,
    cpu_model: Option<String>,
    ram_gb: Option<f64>,
    ram_slots_used: Option<i32>,
    ram_slots_total: Option<i32>,
    ram_speed: Option<String>,
    ram_type: Option<String>,
    ram_slots_usage: Option<String>,
    disk_info: Vec<DiskInfo>,
    logical_disk_specs: Vec<LogicalDiskSpecRow>,
    cpu_cores_temp_c: Vec<CoreTemp>,
    fans: Vec<FanReading>,
}

#[cfg(target_os = "windows")]
impl HwHelperTelemetry {
    fn fallback() -> Self {
        hbb_common::log::warn!("hw_helper: using fallback cpu_temp_c=0.0, fan_rpm=0");
        Self {
            cpu_temp_c: Some(0.0),
            fan_rpm: Some(0),
            cpu_model: None,
            ram_gb: None,
            ram_slots_used: None,
            ram_slots_total: None,
            ram_speed: None,
            ram_type: None,
            ram_slots_usage: None,
            disk_info: Vec::new(),
            logical_disk_specs: Vec::new(),
            cpu_cores_temp_c: Vec::new(),
            fans: Vec::new(),
        }
    }
}

/// Runs `hw_helper.exe`, parses stdout JSON. On any failure returns fallbacks and logs (agent keeps running).
#[cfg(target_os = "windows")]
fn read_lhm_helper_telemetry() -> HwHelperTelemetry {
    use hbb_common::log;
    use std::os::windows::process::CommandExt;
    use std::path::PathBuf;
    use std::process::Command;

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    let Some(exe_dir) = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(PathBuf::from))
    else {
        log::error!("hw_helper: current_exe().parent() unavailable");
        return HwHelperTelemetry::fallback();
    };

    let Some(helper) = resolve_hw_helper_exe(&exe_dir) else {
        log::warn!(
            "hw_helper: executable not found under {:?} (tried Release/net10.0-windows, net8.0-windows, and hw_helper.exe)",
            exe_dir
        );
        return HwHelperTelemetry::fallback();
    };

    let output = match Command::new(&helper)
        .current_dir(&exe_dir)
        .creation_flags(CREATE_NO_WINDOW)
        .output()
    {
        Ok(o) => o,
        Err(e) => {
            log::warn!("hw_helper: spawn failed: {e} ({helper:?})");
            return HwHelperTelemetry::fallback();
        }
    };

    let text = String::from_utf8_lossy(&output.stdout);
    let line = text.trim();
    if line.is_empty() {
        log::warn!(
            "hw_helper: empty stdout (status={}, stderr_len={})",
            output.status,
            output.stderr.len()
        );
        return HwHelperTelemetry::fallback();
    }

    let parsed: LhmHelperOut = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(e) => {
            log::warn!("hw_helper: invalid JSON ({e}): {line:?}");
            return HwHelperTelemetry::fallback();
        }
    };

    let cpu_temp_c = parsed.cpu_temp_c.filter(|t| {
        t.is_finite() && *t >= -40.0 && *t <= 125.0
    });
    let fan_rpm = parsed.fan_rpm;

    log::debug!(
        "hw_helper: cpu_temp_c={:?} fan_rpm={:?} (status={})",
        cpu_temp_c,
        fan_rpm,
        output.status
    );

    let trim_opt = |o: Option<String>| {
        o.map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    };
    let logical_disk_specs = parsed.logical_disk_specs;

    let cpu_cores_temp_c = parsed
        .cpu_cores_temp_c
        .into_iter()
        .filter(|c| c.temp_c.is_finite() && c.temp_c > -40.0 && c.temp_c < 125.0)
        .collect::<Vec<_>>();

    let fans = parsed
        .fans
        .into_iter()
        .filter(|f| f.rpm > 0 && f.rpm < 30000)
        .collect::<Vec<_>>();

    HwHelperTelemetry {
        cpu_temp_c,
        fan_rpm,
        cpu_model: parsed
            .cpu_model
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        ram_gb: parsed.ram_gb.filter(|g| g.is_finite() && *g >= 0.0),
        ram_slots_used: parsed.ram_slots_used.filter(|n| *n >= 0),
        ram_slots_total: parsed.ram_slots_total.filter(|n| *n >= 0),
        ram_speed: trim_opt(parsed.ram_speed),
        ram_type: trim_opt(parsed.ram_type),
        ram_slots_usage: trim_opt(parsed.ram_slots_usage),
        disk_info: parsed.disk_info,
        logical_disk_specs,
        cpu_cores_temp_c,
        fans,
    }
}

#[cfg(all(
    not(any(target_os = "android", target_os = "ios")),
    target_os = "windows"
))]
fn merge_volume_disk_specs(disks: Vec<Value>, specs: &[LogicalDiskSpecRow]) -> Vec<Value> {
    disks
        .into_iter()
        .map(|mut v| {
            if let Some(obj) = v.as_object_mut() {
                let id_norm = obj
                    .get("id")
                    .and_then(|x| x.as_str())
                    .map(normalize_windows_drive_id)
                    .unwrap_or_default();
                let (model, dtype) = specs
                    .iter()
                    .find(|s| normalize_windows_drive_id(s.id.trim()) == id_norm)
                    .map(|s| {
                        (
                            normalize_disk_field(&s.disk_model),
                            normalize_disk_field(&s.disk_type),
                        )
                    })
                    .unwrap_or_else(|| (unknown_string(), unknown_string()));
                obj.insert("disk_model".into(), json!(model));
                obj.insert("disk_type".into(), json!(dtype));
            }
            v
        })
        .collect()
}

#[cfg(all(
    not(any(target_os = "android", target_os = "ios")),
    target_os = "windows"
))]
fn windows_collect() -> Value {
    use serde::Deserialize;
    use wmi::{COMLibrary, WMIConnection};

    #[derive(Deserialize, Debug)]
    #[allow(non_snake_case)]
    struct WinProcessor {
        Name: Option<String>,
        ProcessorId: Option<String>,
    }

    #[derive(Deserialize, Debug)]
    #[allow(non_snake_case)]
    struct WinLogicalDisk {
        DeviceID: Option<String>,
        VolumeName: Option<String>,
        Size: Option<u64>,
        FreeSpace: Option<u64>,
    }

    let mut cpu_name = String::new();
    let mut cpu_processor_id: Option<String> = None;
    let fan_name: Option<String> = None;
    let mut disks: Vec<Value> = Vec::new();

    if let Ok(com) = COMLibrary::new() {
        if let Ok(wmi) = WMIConnection::new(com) {
            if let Ok(procs) = wmi.raw_query::<WinProcessor>(
                "SELECT Name, ProcessorId FROM Win32_Processor",
            )
            {
                if let Some(p) = procs.first() {
                    cpu_name = p.Name.clone().unwrap_or_default().trim().to_string();
                    cpu_processor_id = p
                        .ProcessorId
                        .clone()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty());
                }
            }
        }
    }

    let helper = read_lhm_helper_telemetry();

    let temp_status = helper.cpu_temp_c.map(temp_health).unwrap_or("unknown");
    let fan_status = helper.fan_rpm.map(fan_health).unwrap_or("unknown");

    if let Ok(com) = COMLibrary::new() {
        if let Ok(wmi) = WMIConnection::new(com) {
            if let Ok(parts) = wmi.raw_query::<WinLogicalDisk>(
                "SELECT DeviceID, VolumeName, Size, FreeSpace FROM Win32_LogicalDisk WHERE DriveType = 3",
            ) {
                for d in parts {
                    let size = d.Size.unwrap_or(0);
                    if size == 0 {
                        continue;
                    }
                    let free = d.FreeSpace.unwrap_or(0);
                    let used = size.saturating_sub(free);
                    let used_pct = (used as f64 / size as f64) * 100.0;
                    let free_pct = (free as f64 / size as f64) * 100.0;
                    let id = d.DeviceID.clone().unwrap_or_default();
                    let label = d.VolumeName.clone().unwrap_or_default();
                    disks.push(json!({
                        "id": id,
                        "label": label,
                        "total_gb": (size as f64) / (1024.0 * 1024.0 * 1024.0),
                        "free_gb": (free as f64) / (1024.0 * 1024.0 * 1024.0),
                        "used_pct": used_pct,
                        "free_pct": free_pct,
                        "health": disk_health(free_pct),
                    }));
                }
            }
        }
    }

    if disks.is_empty() {
        disks = disk_entries_from_sysinfo();
    }

    disks = merge_volume_disk_specs(disks, &helper.logical_disk_specs);

    let recommended_actions = read_c_drive_free_pct(&disks)
        .map(recommended_actions_low_c_drive)
        .unwrap_or_default();

    let cpu_log = helper
        .cpu_model
        .clone()
        .unwrap_or_else(|| cpu_name.clone());
    let ram_gb_log = helper
        .ram_gb
        .map(|g| format!("{g:.1}"))
        .unwrap_or_else(|| "?".into());
    let slots_used_log = helper
        .ram_slots_used
        .map(|n| n.to_string())
        .unwrap_or_else(|| "?".into());
    let slots_total_log = helper
        .ram_slots_total
        .map(|n| n.to_string())
        .unwrap_or_else(|| "?".into());
    let ram_speed_log = opt_str_or_unknown(&helper.ram_speed);
    let ram_type_log = opt_str_or_unknown(&helper.ram_type);
    let ram_usage_log = opt_str_or_unknown(&helper.ram_slots_usage);
    hbb_common::log::info!(
        "System Specs: CPU: {}, RAM: {}GB ({}/{}) {} {} slots:{}",
        cpu_log,
        ram_gb_log,
        slots_used_log,
        slots_total_log,
        ram_type_log,
        ram_speed_log,
        ram_usage_log
    );

    let disk_info: Vec<DiskInfo> = helper
        .disk_info
        .iter()
        .map(|d| DiskInfo {
            model: normalize_disk_field(&d.model),
            disk_type: normalize_disk_field(&d.disk_type),
        })
        .collect();

    let hw = HwHealth {
        cpu_name,
        cpu_processor_id,
        cpu_model: helper.cpu_model,
        ram_gb: helper.ram_gb,
        ram_slots_used: helper.ram_slots_used,
        ram_slots_total: helper.ram_slots_total,
        ram_speed: opt_str_or_unknown(&helper.ram_speed),
        ram_type: opt_str_or_unknown(&helper.ram_type),
        ram_slots_usage: opt_str_or_unknown(&helper.ram_slots_usage),
        disk_info,
        cpu_temp_c: helper.cpu_temp_c,
        cpu_cores_temp_c: helper.cpu_cores_temp_c,
        fans: helper.fans,
        fan_rpm: helper.fan_rpm,
        fan_name,
        disks,
        temp_status: temp_status.into(),
        fan_status: fan_status.into(),
        recommended_actions,
    };
    serde_json::to_value(&hw).unwrap_or_else(|_| json!({}))
}

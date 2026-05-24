//! GCS backup helper: runs on stock Windows PowerShell 5.1 / no pwsh — invoked from .bat only.
#![forbid(unsafe_code)]

use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, KeyInit};
use chrono::{Local, Utc};
use regex::Regex;
use serde::Deserialize;
use serde::Serialize;
use sha2::Digest;
use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::thread;
use std::time::Duration;

const GCS_BUCKET_NAME: &str = "my-saas-uploads-2025";
const REMOTE_BACKUP_ROOT: &str = "seedesktop/backups";
const MAGIC: &[u8; 4] = b"SDG1";
const KEY_MATERIAL: &[u8] = b"SeeDesktop-gcs-blob-v1";
const DEFAULT_GCS_CREDENTIALS_BLOB_URL: &str =
    "https://seedesktop.com/elivc/public_html/downloads/admin/gcs_credentials.dat";
const SEE_DESKTOP_EXE: &str = "SeeDesktop.exe";
const MAX_BACKUPS: usize = 3;
/// Matches `flutter/windows/runner/Runner.rc` (path_provider_windows Roaming + Local).
#[cfg(windows)]
const WIN_FLUTTER_COMPANY: &str = "Toppc";
#[cfg(windows)]
const WIN_FLUTTER_PRODUCT: &str = "SeeDesktop";
#[cfg(windows)]
const STAGING_FLUTTER_SUPPORT: &str = "FlutterSupport";
#[cfg(windows)]
const STAGING_FLUTTER_LOCAL: &str = "FlutterLocal";
const USER_AGENT: &str = "SeeDesktop-backup-helper/1.0";
/// Local encrypted address book blob (`config::Ab`); excluded from backup/restore.
const AB_DATA_FILENAME: &str = "SeeDesktop_ab";
const AB_RESTORE_MERGE_FLAG: &str = "ab_restore_merge_pending";

type DynErr = Box<dyn Error + Send + Sync>;

#[derive(Debug, Deserialize)]
struct ServiceAccount {
    client_email: String,
    private_key: String,
    token_uri: String,
}

#[derive(Debug, Serialize)]
struct JwtClaims {
    iss: String,
    scope: String,
    aud: String,
    exp: i64,
    iat: i64,
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
}

#[derive(Debug, Deserialize)]
struct GcsListResponse {
    items: Option<Vec<GcsObject>>,
    #[serde(rename = "nextPageToken")]
    next_page_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GcsObject {
    name: String,
}

#[derive(Debug, Serialize)]
struct BackupListItem {
    stamp: String,
    label: String,
}

fn blob_url_from_api_base(api: &str) -> String {
    if let Ok(override_url) = std::env::var("SEEDESKTOP_GCS_BLOB_URL") {
        let t = override_url.trim();
        if !t.is_empty() {
            return t.to_string();
        }
    }
    if std::env::var("SEEDESKTOP_GCS_BLOB_USE_API").unwrap_or_default() == "1" && !api.trim().is_empty()
    {
        let b = api.trim().trim_end_matches('/');
        return format!("{b}/seedesktop/gcs_credentials.dat");
    }
    DEFAULT_GCS_CREDENTIALS_BLOB_URL.to_string()
}

fn decrypt_credentials_blob(raw: &[u8]) -> Result<Vec<u8>, DynErr> {
    if raw.len() < 4 + 12 + 16 {
        return Err("blob too short".into());
    }
    if &raw[..4] != MAGIC {
        return Err("invalid blob magic (expected SDG1 encrypted .dat)".into());
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&sha2::Sha256::digest(KEY_MATERIAL));
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|e| e.to_string())?;
    let nonce = aes_gcm::Nonce::from_slice(&raw[4..16]);
    let plain = cipher
        .decrypt(nonce, raw[16..].as_ref())
        .map_err(|_| -> DynErr { "AES-GCM decrypt failed (wrong key or corrupt blob)".into() })?;
    let _: serde_json::Value = serde_json::from_slice(&plain)?;
    Ok(plain)
}

fn http_client() -> Result<reqwest::blocking::Client, DynErr> {
    Ok(reqwest::blocking::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(std::time::Duration::from_secs(120))
        .build()?)
}

fn fetch_blob_bytes(url: &str) -> Result<Vec<u8>, DynErr> {
    let client = http_client()?;
    let resp = client.get(url).send()?.error_for_status()?;
    Ok(resp.bytes()?.to_vec())
}

fn load_service_account(api_base: Option<&str>) -> Result<ServiceAccount, DynErr> {
    if let Some(api) = api_base {
        let a = api.trim();
        if !a.is_empty() {
            let url = blob_url_from_api_base(a);
            let raw = fetch_blob_bytes(&url)?;
            let plain = decrypt_credentials_blob(&raw)?;
            let sa: ServiceAccount = serde_json::from_slice(&plain)?;
            return Ok(sa);
        }
    }
    if let Ok(p) = std::env::var("SEEDESKTOP_GCS_CREDENTIALS") {
        let p = p.trim();
        if !p.is_empty() && Path::new(p).is_file() {
            let s = fs::read_to_string(p)?;
            return Ok(serde_json::from_str(&s)?);
        }
    }
    if let Ok(la) = std::env::var("LOCALAPPDATA") {
        let p = PathBuf::from(la).join("SeeDesktop").join("cloud").join("gcs_credentials.json");
        if p.is_file() {
            let s = fs::read_to_string(&p)?;
            return Ok(serde_json::from_str(&s)?);
        }
    }
    let legacy = exe_dir().join("credentials.json");
    if legacy.is_file() {
        let s = fs::read_to_string(&legacy)?;
        return Ok(serde_json::from_str(&s)?);
    }
    Err(
        "GCS credentials not found (API base for encrypted .dat, SEEDESKTOP_GCS_CREDENTIALS, LocalAppData json, or credentials.json next to exe)."
            .into(),
    )
}

fn get_access_token(sa: &ServiceAccount) -> Result<String, DynErr> {
    let now = Utc::now().timestamp();
    let claims = JwtClaims {
        iss: sa.client_email.clone(),
        scope: "https://www.googleapis.com/auth/devstorage.read_write".to_string(),
        aud: sa.token_uri.clone(),
        exp: now + 3600,
        iat: now,
    };
    let key = jsonwebtoken::EncodingKey::from_rsa_pem(sa.private_key.as_bytes())?;
    let header = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::RS256);
    let assertion = jsonwebtoken::encode(&header, &claims, &key)?;

    let client = http_client()?;
    let mut form = HashMap::new();
    form.insert(
        "grant_type",
        "urn:ietf:params:oauth:grant-type:jwt-bearer".to_string(),
    );
    form.insert("assertion", assertion);

    let tr: TokenResponse = client
        .post(&sa.token_uri)
        .form(&form)
        .send()?
        .error_for_status()?
        .json()?;
    if tr.access_token.is_empty() {
        return Err("Failed to obtain access token.".into());
    }
    Ok(tr.access_token)
}

fn sanitize_email(mail: &str) -> String {
    let mut s = mail.trim().to_lowercase();
    if s.is_empty() {
        return "unknown".to_string();
    }
    s = s.replace('@', "_at_");
    for bad in ["/", "\\", "..", ":", "*", "?", "\"", "<", ">", "|"] {
        s = s.replace(bad, "_");
    }
    if s.is_empty() {
        "unknown".to_string()
    } else {
        s
    }
}

fn prefix_for_email(mail: &str) -> String {
    format!(
        "{}/{}/SeeDesktop/",
        REMOTE_BACKUP_ROOT,
        sanitize_email(mail)
    )
}

static STAMP_RE: OnceLock<Regex> = OnceLock::new();

fn parse_stamp(filename: &str) -> Option<String> {
    let re = STAMP_RE.get_or_init(|| Regex::new(r"^backup_(\d{8}_\d{6})\.zip$").unwrap());
    re.captures(filename)
        .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
}

fn stamp_to_label(stamp: &str) -> String {
    if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(stamp, "%Y%m%d_%H%M%S") {
        return dt.format("%Y-%m-%d %H:%M:%S").to_string();
    }
    stamp.to_string()
}

fn gcs_object_url(bucket: &str, object_name: &str) -> String {
    let enc = urlencoding_gcs(object_name);
    format!("https://storage.googleapis.com/storage/v1/b/{bucket}/o/{enc}")
}

/// Minimal percent-encoding for GCS object paths (same as typical Uri.EscapeDataString usage).
fn urlencoding_gcs(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.as_bytes() {
        match *b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

fn exe_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_default()
}

#[cfg(windows)]
fn kill_seedesktop() {
    let _ = Command::new("taskkill")
        .args(["/F", "/IM", SEE_DESKTOP_EXE])
        .output();
}

#[cfg(not(windows))]
fn kill_seedesktop() {}

/// Restore optional folder from new-format backups (`backup_package.ps1`).
#[cfg(windows)]
fn install_optional_staging_folder(
    staging_root: &Path,
    folder_name: &str,
    target: &Path,
) -> Result<(), DynErr> {
    let src = staging_root.join(folder_name);
    if !src.is_dir() {
        return Ok(());
    }
    if fs::read_dir(&src)?.next().is_none() {
        return Ok(());
    }
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent)?;
    }
    let leaf = target
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("bundle");
    let bak_path = target
        .parent()
        .ok_or_else(|| -> DynErr { "bundle target has no parent directory".into() })?
        .join(format!("{leaf}_sd_bak_{}", uuid_simple()));
    let had_old = target.is_dir();
    if had_old {
        fs::rename(target, &bak_path)?;
    }
    if fs::rename(&src, target).is_err() {
        copy_dir_all(&src, target).map_err(|e| -> DynErr {
            if target.exists() {
                let _ = fs::remove_dir_all(target);
            }
            if had_old && bak_path.is_dir() {
                let _ = fs::rename(&bak_path, target);
            }
            format!("restore {folder_name} failed ({e})").into()
        })?;
        let _ = fs::remove_dir_all(&src);
    }
    if had_old && bak_path.is_dir() {
        let _ = fs::remove_dir_all(&bak_path);
    }
    Ok(())
}

/// Remove address-book files so cloud backup/restore does not touch AB data.
fn strip_address_book_data(dir: &Path) {
    let _ = fs::remove_file(dir.join(AB_DATA_FILENAME));
    let _ = fs::remove_file(dir.join(AB_RESTORE_MERGE_FLAG));
}

fn copy_dir_all(src: &Path, dst: &Path) -> Result<(), DynErr> {
    if !src.is_dir() {
        return Err("copy_dir_all: source is not a directory".into());
    }
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        if from.is_dir() {
            copy_dir_all(&from, &to)?;
        } else {
            fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

/// Extract the zip into `staging_root`, then return the path to the `SeeDesktop` folder inside.
/// Does not touch `%APPDATA%\SeeDesktop` — safe to run while the app is still running.
fn extract_zip_to_staging(zip_path: &Path, staging_root: &Path) -> Result<PathBuf, DynErr> {
    let file = fs::File::open(zip_path)?;
    let mut archive = zip::ZipArchive::new(file)?;
    if archive.len() == 0 {
        return Err("backup archive is empty".into());
    }
    if staging_root.exists() {
        fs::remove_dir_all(staging_root)?;
    }
    fs::create_dir_all(staging_root)?;
    let mut file_count: u32 = 0;
    for i in 0..archive.len() {
        let mut zf = archive.by_index(i)?;
        let Some(rel) = zf.enclosed_name().map(|p| p.to_path_buf()) else {
            continue;
        };
        let outpath = staging_root.join(&rel);
        let name = zf.name();
        let is_dir = name.ends_with('/') || name.ends_with('\\');
        if is_dir {
            fs::create_dir_all(&outpath)?;
        } else {
            file_count += 1;
            if let Some(parent) = outpath.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut outfile = fs::File::create(&outpath)?;
            std::io::copy(&mut zf, &mut outfile)?;
        }
    }
    if file_count == 0 {
        return Err("backup archive contained no files (only folders?)".into());
    }
    let sd = resolve_seedesktop_root(staging_root)?;
    strip_address_book_data(&sd);
    Ok(sd)
}

fn resolve_seedesktop_root(staging_root: &Path) -> Result<PathBuf, DynErr> {
    let direct = staging_root.join("SeeDesktop");
    if direct.is_dir() {
        return Ok(direct);
    }
    for entry in fs::read_dir(staging_root)? {
        let entry = entry?;
        let p = entry.path();
        if p.is_dir() {
            if let Some(name) = p.file_name().and_then(|s| s.to_str()) {
                if name.eq_ignore_ascii_case("seedesktop") {
                    return Ok(p);
                }
            }
        }
    }
    Err(
        "invalid backup zip: expected a top-level SeeDesktop folder (as created by Windows backup)."
            .into(),
    )
}

fn cmd_upload(email: &str, local_zip: &str, api_base: Option<&str>) -> Result<(), DynErr> {
    let path = Path::new(local_zip);
    if !path.is_file() {
        return Err(format!("zip not found: {local_zip}").into());
    }
    let sa = load_service_account(api_base)?;
    let token = get_access_token(&sa)?;
    let prefix = prefix_for_email(email);
    let stamp = Local::now().format("%Y%m%d_%H%M%S").to_string();
    let object_name = format!("{prefix}backup_{stamp}.zip");
    let upload_url = format!(
        "https://storage.googleapis.com/upload/storage/v1/b/{GCS_BUCKET_NAME}/o?uploadType=media&name={}",
        urlencoding_gcs(&object_name)
    );
    let client = http_client()?;
    let bytes = fs::read(path)?;
    client
        .post(&upload_url)
        .header("Authorization", format!("Bearer {token}"))
        .header("Content-Type", "application/zip")
        .body(bytes)
        .send()?
        .error_for_status()?;

    // Prune older backups (keep latest MAX_BACKUPS)
    let mut all: Vec<GcsObject> = Vec::new();
    let mut page_token: Option<String> = None;
    loop {
        let mut url = format!(
            "https://storage.googleapis.com/storage/v1/b/{GCS_BUCKET_NAME}/o?prefix={}",
            urlencoding_gcs(&prefix)
        );
        if let Some(ref pt) = page_token {
            url.push_str("&pageToken=");
            url.push_str(&urlencoding_gcs(pt));
        }
        let resp: GcsListResponse = client
            .get(&url)
            .header("Authorization", format!("Bearer {token}"))
            .send()?
            .error_for_status()?
            .json()?;
        if let Some(items) = resp.items {
            all.extend(items);
        }
        page_token = resp.next_page_token;
        if page_token.as_ref().map(|s| s.is_empty()).unwrap_or(true) {
            break;
        }
    }

    let mut backups: Vec<(String, String)> = Vec::new();
    for it in &all {
        let leaf = Path::new(&it.name)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        if let Some(st) = parse_stamp(leaf) {
            backups.push((it.name.clone(), st));
        }
    }
    backups.sort_by(|a, b| b.1.cmp(&a.1));
    if backups.len() > MAX_BACKUPS {
        for (name, _) in backups.iter().skip(MAX_BACKUPS) {
            let del_url = gcs_object_url(GCS_BUCKET_NAME, name);
            let _ = client
                .delete(&del_url)
                .header("Authorization", format!("Bearer {token}"))
                .send();
        }
    }
    Ok(())
}

fn cmd_list_json(email: &str, api_base: Option<&str>) -> Result<(), DynErr> {
    let sa = load_service_account(api_base)?;
    let token = get_access_token(&sa)?;
    let prefix = prefix_for_email(email);
    let client = http_client()?;
    let mut all: Vec<GcsObject> = Vec::new();
    let mut page_token: Option<String> = None;
    loop {
        let mut url = format!(
            "https://storage.googleapis.com/storage/v1/b/{GCS_BUCKET_NAME}/o?prefix={}",
            urlencoding_gcs(&prefix)
        );
        if let Some(ref pt) = page_token {
            url.push_str("&pageToken=");
            url.push_str(&urlencoding_gcs(pt));
        }
        let resp: GcsListResponse = client
            .get(&url)
            .header("Authorization", format!("Bearer {token}"))
            .send()?
            .error_for_status()?
            .json()?;
        if let Some(items) = resp.items {
            all.extend(items);
        }
        page_token = resp.next_page_token;
        if page_token.as_ref().map(|s| s.is_empty()).unwrap_or(true) {
            break;
        }
    }

    let mut items: Vec<BackupListItem> = Vec::new();
    for it in all {
        let leaf = Path::new(&it.name)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        if let Some(st) = parse_stamp(leaf) {
            items.push(BackupListItem {
                label: stamp_to_label(&st),
                stamp: st,
            });
        }
    }
    items.sort_by(|a, b| b.stamp.cmp(&a.stamp));
    println!("{}", serde_json::to_string(&items)?);
    Ok(())
}

fn cmd_restore(email: &str, stamp: &str, api_base: Option<&str>) -> Result<(), DynErr> {
    #[cfg(not(windows))]
    {
        let _ = (email, stamp, api_base);
        return Err("restore is only supported on Windows".into());
    }

    #[cfg(windows)]
    {
        let stamp = stamp.trim();
        if stamp.is_empty() {
            return Err("stamp is required".into());
        }
        let sa = load_service_account(api_base)?;
        let token = get_access_token(&sa)?;
        let prefix = prefix_for_email(email);
        let object_name = format!("{prefix}backup_{stamp}.zip");
        let obj_url = format!(
            "{}?alt=media",
            gcs_object_url(GCS_BUCKET_NAME, &object_name)
        );

        let tmp_dir = std::env::temp_dir().join(format!("sd_restore_{}", uuid_simple()));
        fs::create_dir_all(&tmp_dir)?;
        let zip_path = tmp_dir.join("restore.zip");

        let result = (|| -> Result<(), DynErr> {
            let appdata = std::env::var("APPDATA")
                .map_err(|_| -> DynErr { "APPDATA is not set".into() })?;
            let appdata_path = PathBuf::from(&appdata);
            let target_dir = appdata_path.join("SeeDesktop");
            let staging_root = tmp_dir.join("staging");

            let client = http_client()?;
            let mut resp = client
                .get(&obj_url)
                .header("Authorization", format!("Bearer {token}"))
                .send()?
                .error_for_status()?;
            let mut f = fs::File::create(&zip_path)?;
            std::io::copy(&mut resp, &mut f)?;
            drop(f);

            // Validate and extract while the app may still be running — never delete live data yet.
            let staging_sd = extract_zip_to_staging(&zip_path, &staging_root)?;

            kill_seedesktop();
            thread::sleep(Duration::from_secs(2));

            let bak_name = format!("SeeDesktop_sd_bak_{}", uuid_simple());
            let bak_path = appdata_path.join(&bak_name);
            let had_old = target_dir.is_dir();
            if had_old {
                fs::rename(&target_dir, &bak_path)?;
            }

            if fs::rename(&staging_sd, &target_dir).is_err() {
                copy_dir_all(&staging_sd, &target_dir).map_err(|e| -> DynErr {
                    if target_dir.exists() {
                        let _ = fs::remove_dir_all(&target_dir);
                    }
                    if had_old && bak_path.is_dir() {
                        let _ = fs::rename(&bak_path, &target_dir);
                    }
                    format!(
                        "restore failed while copying data ({e}); previous folder was restored if it existed."
                    )
                    .into()
                })?;
            }

            if had_old && bak_path.is_dir() {
                let _ = fs::remove_dir_all(&bak_path);
            }

            let flutter_roam = appdata_path
                .join(WIN_FLUTTER_COMPANY)
                .join(WIN_FLUTTER_PRODUCT);
            install_optional_staging_folder(
                &staging_root,
                STAGING_FLUTTER_SUPPORT,
                &flutter_roam,
            )?;

            let localappdata = std::env::var("LOCALAPPDATA")
                .map_err(|_| -> DynErr { "LOCALAPPDATA is not set".into() })?;
            let flutter_local = PathBuf::from(localappdata)
                .join(WIN_FLUTTER_COMPANY)
                .join(WIN_FLUTTER_PRODUCT);
            install_optional_staging_folder(
                &staging_root,
                STAGING_FLUTTER_LOCAL,
                &flutter_local,
            )?;

            let _ = fs::remove_dir_all(&staging_root);

            // Do not restore address book from backup; keep current AB / cloud sync only.
            strip_address_book_data(&target_dir);

            // GUI restart is done by restore.bat (start "" /D ...) so it survives this process exit.
            Ok(())
        })();

        let _ = fs::remove_dir_all(&tmp_dir);
        result
    }
}

fn uuid_simple() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{n:x}")
}

fn parse_api_base(argv: &[String], idx: usize) -> Option<String> {
    if let Some(s) = argv.get(idx) {
        let t = s.trim().to_string();
        if !t.is_empty() {
            return Some(t);
        }
    }
    std::env::var("SEEDESKTOP_API_SERVER")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    if argv.len() < 2 {
        eprintln!(
            "Usage:\n  seedesktop_backup_helper upload <email> <zip> [api_base]\n  seedesktop_backup_helper list-json <email> [api_base]\n  seedesktop_backup_helper restore <email> <stamp> [api_base]"
        );
        std::process::exit(2);
    }
    let cmd = argv[1].to_lowercase();
    let r: Result<(), DynErr> = match cmd.as_str() {
        "upload" => {
            if argv.len() < 4 {
                Err("upload requires email and zip path".into())
            } else {
                let api = parse_api_base(&argv, 4);
                cmd_upload(&argv[2], &argv[3], api.as_deref())
            }
        }
        "list-json" => {
            if argv.len() < 3 {
                Err("list-json requires email".into())
            } else {
                let api = parse_api_base(&argv, 3);
                cmd_list_json(&argv[2], api.as_deref())
            }
        }
        "restore" => {
            if argv.len() < 4 {
                Err("restore requires email and stamp".into())
            } else {
                let api = parse_api_base(&argv, 4);
                cmd_restore(&argv[2], &argv[3], api.as_deref())
            }
        }
        _ => Err(format!("Unknown command: {}", argv[1]).into()),
    };
    if let Err(e) = r {
        eprintln!("{e}");
        std::process::exit(1);
    }
}

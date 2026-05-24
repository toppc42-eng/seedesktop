use super::{
    driver::{get_installed_driver_version, install_driver, uninstall_driver},
    port::{check_add_local_port, check_delete_local_port},
    printer::{add_printer, delete_printer},
};
use hbb_common::{allow_err, bail, lazy_static, log, ResultType};
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;
use std::{
    path::PathBuf,
    process::{Command, ExitStatus},
    sync::Mutex,
};
use windows_strings::PCWSTR;

lazy_static::lazy_static!(
    static ref SETUP_MTX: Mutex<()> = Mutex::new(());
);

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW_FLAG: u32 = 0x08000000;

fn status_hidden(cmd: &mut Command) -> std::io::Result<ExitStatus> {
    #[cfg(target_os = "windows")]
    {
        cmd.creation_flags(CREATE_NO_WINDOW_FLAG);
    }
    cmd.status()
}

fn ps_single_quote(s: &str) -> String {
    s.replace('\'', "''")
}

fn rename_printer_queue(from_name: &str, to_name: &str) -> ResultType<()> {
    if from_name.eq_ignore_ascii_case(to_name) {
        return Ok(());
    }
    let from = ps_single_quote(from_name);
    let to = ps_single_quote(to_name);
    let script = format!(
        "$ErrorActionPreference='Stop'; \
         $src='{from}'; \
         $dst='{to}'; \
         $srcPrinter=Get-Printer -Name $src -ErrorAction SilentlyContinue; \
         if (-not $srcPrinter) {{ exit 0 }}; \
         $dstPrinter=Get-Printer -Name $dst -ErrorAction SilentlyContinue; \
         if ($dstPrinter) {{ exit 0 }}; \
         Rename-Printer -Name $src -NewName $dst -ErrorAction Stop"
    );
    let status = status_hidden(Command::new("powershell").args([
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        &script,
    ]))?;
    if !status.success() {
        bail!(
            "Failed to rename printer queue from '{}' to '{}'",
            from_name,
            to_name
        );
    }
    Ok(())
}

fn install_driver_silently_with_system_tools(inf_path: &str, driver_name: &str) -> ResultType<()> {
    let pnp_status =
        status_hidden(Command::new("pnputil").args(["/add-driver", inf_path, "/install"]))?;
    if pnp_status.success() {
        return Ok(());
    }

    // Fallback path for systems where pnputil install path is blocked.
    let printui_status = status_hidden(Command::new("rundll32.exe").args([
        "printui.dll,PrintUIEntry",
        "/ia",
        "/m",
        driver_name,
        "/h",
        "x64",
        "/v",
        "Type 3 - User Mode",
        "/f",
        inf_path,
        "/q",
    ]))?;
    if !printui_status.success() {
        bail!("Failed to silently stage/install printer driver via pnputil and printui");
    }
    Ok(())
}

fn get_driver_inf_abs_path() -> ResultType<PathBuf> {
    use crate::RD_DRIVER_INF_PATH;

    let exe_file = std::env::current_exe()?;
    let abs_path = match exe_file.parent() {
        Some(parent) => parent.join(RD_DRIVER_INF_PATH),
        None => bail!(
            "Invalid exe parent for {}",
            exe_file.to_string_lossy().as_ref()
        ),
    };
    if !abs_path.exists() {
        bail!(
            "The driver inf file \"{}\" does not exists",
            RD_DRIVER_INF_PATH
        )
    }
    Ok(abs_path)
}

// Note: This function must be called in a separate thread.
// Because many functions in this module are blocking or synchronous.
// Calling this function from a thread that manages interaction with the user interface could make the application appear to be unresponsive.
// Steps:
// 1. Add the local port.
// 2. Check if the driver is installed.
//    Uninstall the existing driver if it is installed.
//    We should not check the driver version because the driver is deployed with the application.
//    It's better to uninstall the existing driver and install the driver from the application.
// 3. Add the printer.
pub fn install_update_printer(app_name: &str) -> ResultType<()> {
    let app_printer_name = format!("{} Printer", app_name);
    let legacy_printer_name = "RustDesk Printer"
        .encode_utf16()
        .chain(Some(0))
        .collect::<Vec<u16>>();
    let legacy_printer_name_text = "RustDesk Printer";
    let target_printer_name_text = "SeeDesktop Printer";
    let printer_name = crate::get_printer_name(app_name);
    let custom_printer_name = crate::get_custom_printer_name();
    let driver_name = crate::get_driver_name();
    let port = crate::get_port_name(app_name);
    let legacy_rd_printer_name = PCWSTR::from_raw(legacy_printer_name.as_ptr());
    let rd_printer_name = PCWSTR::from_raw(printer_name.as_ptr());
    let custom_rd_printer_name = PCWSTR::from_raw(custom_printer_name.as_ptr());
    let rd_printer_driver_name = PCWSTR::from_raw(driver_name.as_ptr());
    let rd_printer_port = PCWSTR::from_raw(port.as_ptr());

    let inf_file = get_driver_inf_abs_path()?;
    let inf_file: Vec<u16> = inf_file
        .to_string_lossy()
        .as_ref()
        .encode_utf16()
        .chain(Some(0).into_iter())
        .collect();
    let _lock = SETUP_MTX.lock().unwrap();

    check_add_local_port(&rd_printer_port)?;

    let should_install_driver = match get_installed_driver_version(&rd_printer_driver_name)? {
        Some(_version) => {
            allow_err!(delete_printer(&rd_printer_name));
            allow_err!(delete_printer(&custom_rd_printer_name));
            allow_err!(uninstall_driver(&rd_printer_driver_name));
            true
        }
        None => true,
    };

    if should_install_driver {
        if let Some(inf_path) = inf_file.get(..inf_file.len().saturating_sub(1)) {
            let inf_path = String::from_utf16_lossy(inf_path);
            allow_err!(install_driver_silently_with_system_tools(
                &inf_path,
                "RustDesk v4 Printer Driver"
            ));
        }
        allow_err!(install_driver(&rd_printer_driver_name, inf_file.as_ptr()));
    }

    // Create queue with original name first (trusted signed package flow),
    // then rename it immediately to product branding.
    allow_err!(delete_printer(&legacy_rd_printer_name));
    allow_err!(delete_printer(&rd_printer_name));
    allow_err!(delete_printer(&custom_rd_printer_name));
    add_printer(
        &legacy_rd_printer_name,
        &rd_printer_driver_name,
        &rd_printer_port,
    )?;
    allow_err!(rename_printer_queue(
        legacy_printer_name_text,
        target_printer_name_text
    ));
    allow_err!(rename_printer_queue(
        &app_printer_name,
        target_printer_name_text
    ));

    Ok(())
}

pub fn uninstall_printer(app_name: &str) {
    let legacy_printer_name = "RustDesk Printer"
        .encode_utf16()
        .chain(Some(0))
        .collect::<Vec<u16>>();
    let printer_name = crate::get_printer_name(app_name);
    let custom_printer_name = crate::get_custom_printer_name();
    let driver_name = crate::get_driver_name();
    let port = crate::get_port_name(app_name);
    let legacy_rd_printer_name = PCWSTR::from_raw(legacy_printer_name.as_ptr());
    let rd_printer_name = PCWSTR::from_raw(printer_name.as_ptr());
    let custom_rd_printer_name = PCWSTR::from_raw(custom_printer_name.as_ptr());
    let rd_printer_driver_name = PCWSTR::from_raw(driver_name.as_ptr());
    let rd_printer_port = PCWSTR::from_raw(port.as_ptr());

    let _lock = SETUP_MTX.lock().unwrap();

    allow_err!(delete_printer(&legacy_rd_printer_name));
    allow_err!(delete_printer(&rd_printer_name));
    allow_err!(delete_printer(&custom_rd_printer_name));
    allow_err!(uninstall_driver(&rd_printer_driver_name));
    allow_err!(check_delete_local_port(&rd_printer_port));
}

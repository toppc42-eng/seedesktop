use hbb_common::{log, ResultType};
use std::{
    fs::OpenOptions,
    io::Write,
    thread,
};

pub const NAME: &'static str = "remote-printer";
// The pipe tag used by the signed RustDesk XPS render filter DLL
const COMPAT_PRINTER_PIPE_TAG: &str = "RustDesk";
const PRINTER_SERVICE_DIAG_FILE: &str = r"C:\Windows\Temp\seedesktop_printer_service.txt";

fn diag_log(msg: &str) {
    if let Ok(mut f) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(PRINTER_SERVICE_DIAG_FILE)
    {
        let _ = writeln!(f, "{}", msg);
    }
}

/// Start the printer capture service for the user-session server process.
pub fn start() -> ResultType<()> {
    // Only used for direct (non-service) launches, which usually fail to create the
    // global named pipe due to missing SYSTEM permissions.
    Ok(())
}

/// Start the printer capture service from the SYSTEM Windows service process.
/// Creates a named pipe that the XPS render filter writes to. Captured XPS jobs
/// are forwarded to the user-session server via the IPC channel (`Data::PrinterData`).
pub fn start_in_service() {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        thread::spawn(|| {
            diag_log("start_in_service: Rust-native named pipe listener started");
            let rt = match hbb_common::tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    log::error!("Failed to create tokio runtime for printer pipe: {}", e);
                    diag_log(&format!("start_in_service: runtime build failed: {}", e));
                    return;
                }
            };

            rt.block_on(async {
                run_printer_pipe_listener().await;
            });
        });
    });
}

/// Native async implementation of the printer pipe listener.
/// Listens on the well-known RDP virtual channel pipe used by the RustDesk XPS filter.
async fn run_printer_pipe_listener() {
    use parity_tokio_ipc::{Endpoint, SecurityAttributes};
    use hbb_common::tokio::io::AsyncReadExt;
    
    // The RustDesk render filter hardcodes the pipe name prefix
    let pipe_name = format!(r"\\.\pipe\rdpdr\query-raw\{}", COMPAT_PRINTER_PIPE_TAG);
    
    diag_log(&format!("Listening on pipe: {}", pipe_name));
    log::info!("Printer service starting listener on: {}", pipe_name);

    let mut endpoint = Endpoint::new(pipe_name.clone());
    match SecurityAttributes::allow_everyone_create() {
        Ok(attr) => endpoint.set_security_attributes(attr),
        Err(e) => {
            log::error!("Failed to set printer pipe security: {}", e);
            diag_log(&format!("pipe security error: {}", e));
        }
    }

    let mut incoming = match endpoint.incoming() {
        Ok(incoming) => incoming,
        Err(e) => {
            log::error!("Failed to create incoming printer pipe: {}", e);
            diag_log(&format!("pipe incoming error: {}", e));
            return;
        }
    };

    use hbb_common::futures::StreamExt;
    
    while let Some(result) = incoming.next().await {
        match result {
            Ok(mut stream) => {
                diag_log("Print spooler filter connected to pipe");
                log::info!("Print job started: XPS filter connected");
                
                hbb_common::tokio::spawn(async move {
                    let mut data = Vec::new();
                    let mut buf = [0u8; 65536];
                    
                    loop {
                        match stream.read(&mut buf).await {
                            Ok(0) => break, // EOF
                            Ok(n) => {
                                data.extend_from_slice(&buf[..n]);
                            }
                            Err(e) => {
                                log::warn!("Error reading from printer pipe: {}", e);
                                diag_log(&format!("pipe read error: {}", e));
                                break;
                            }
                        }
                    }
                    
                    diag_log(&format!("Pipe closed. Read {} bytes", data.len()));

                    if data.is_empty() {
                        return;
                    }

                    // The render filter may prepend private framing bytes before the ZIP/XPS stream.
                    // Try to locate a valid XPS ZIP header and forward only the actual payload.
                    if let Some(xps_payload) = extract_xps_payload(&data) {
                        if xps_payload.len() != data.len() {
                            diag_log(&format!(
                                "Extracted XPS payload from framed data: original_len={}, xps_len={}",
                                data.len(),
                                xps_payload.len()
                            ));
                        }
                        diag_log("Forwarding XPS payload to IPC...");
                        forward_printer_data_to_ipc(xps_payload).await;
                    } else {
                        diag_log(&format!(
                            "Ignored non-XPS payload: len={}, first_bytes={:02X} {:02X} {:02X} {:02X}",
                            data.len(),
                            data.first().copied().unwrap_or_default(),
                            data.get(1).copied().unwrap_or_default(),
                            data.get(2).copied().unwrap_or_default(),
                            data.get(3).copied().unwrap_or_default()
                        ));
                    }
                });
            }
            Err(e) => {
                log::error!("Printer named pipe connect error: {}", e);
            }
        }
    }
}

fn extract_xps_payload(data: &[u8]) -> Option<Vec<u8>> {
    const ZIP_MAGIC: &[u8] = b"PK\x03\x04";
    if data.len() < ZIP_MAGIC.len() {
        return None;
    }
    if data.starts_with(ZIP_MAGIC) {
        return Some(data.to_vec());
    }
    // Some driver builds prepend framing bytes before the real XPS stream.
    // Look for the first ZIP local-file header and strip everything before it.
    if let Some(pos) = data.windows(ZIP_MAGIC.len()).position(|w| w == ZIP_MAGIC) {
        let payload = &data[pos..];
        if payload.len() >= 4096 {
            return Some(payload.to_vec());
        }
    }
    None
}

/// Forward captured printer data to the user-session server via IPC.
async fn forward_printer_data_to_ipc(data: Vec<u8>) {
    match crate::ipc::connect(1000, "").await {
        Ok(mut conn) => {
            diag_log("ipc connect: success");
            hbb_common::allow_err!(
                conn.send(&crate::ipc::Data::PrinterData(data)).await
            );
            diag_log("ipc send PrinterData: attempted");
        }
        Err(e) => {
            log::warn!("Printer service (SYSTEM): cannot connect to server IPC: {}", e);
            diag_log(&format!("ipc connect failed: {}", e));
        }
    }
}

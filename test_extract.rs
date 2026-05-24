fn main() {
    let content = std::fs::read("C:\\Program Files\\SeeDesktop\\printer_driver_adapter.dll").unwrap();
    let mut i = 0;
    while i < content.len() - 10 {
        if content[i] == b'p' && content[i+1] == b'i' && content[i+2] == b'p' && content[i+3] == b'e' {
            let mut s = String::new();
            let mut j = i.saturating_sub(10);
            while j < i + 50 && j < content.len() {
                if content[j] >= 32 && content[j] <= 126 {
                    s.push(content[j] as char);
                } else {
                    s.push('.');
                }
                j += 1; // Assuming UTF-8/ASCII
            }
            println!("Adapter context around pipe (ASCII): {}", s);
        }
        i += 1;
    }
}

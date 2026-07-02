#![no_main]
use libfuzzer_sys::fuzz_target;
use std::io::Write;

fuzz_target!(|data: &[u8]| {
    // Write fuzz data to a temp file so the parser can read it.
    let dir = std::env::temp_dir();
    let path = dir.join("mmforge_fuzz.dxf");
    if std::fs::File::create(&path)
        .and_then(|mut f| f.write_all(data))
        .is_err()
    {
        return;
    }
    // The parser must never panic on malformed input.
    let _ = mmforge_format_dxf::parse_dxf(&path);
    let _ = std::fs::remove_file(&path);
});

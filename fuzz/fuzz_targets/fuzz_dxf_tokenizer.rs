#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // Convert bytes to UTF-8 string (lossy), then tokenize.
    let content = String::from_utf8_lossy(data);
    let mut tokenizer = mmforge_format_dxf::DxfTokenizer::new(&content);
    let _pairs = tokenizer.collect_all();
});

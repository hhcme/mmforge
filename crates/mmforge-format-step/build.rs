//! Build script for mmforge-format-step.
//!
//! When the `occt` feature is enabled, checks whether the OCCT shim
//! library is available and sets the `occt_found` cfg accordingly.
//!
//! This mirrors the detection logic in mmforge-geometry's build.rs
//! but only emits the `occt_found` cfg — link directives are handled
//! by mmforge-geometry.

fn main() {
    println!("cargo::rustc-check-cfg=cfg(occt_found)");

    #[cfg(feature = "occt")]
    detect_occt();
}

#[cfg(feature = "occt")]
fn detect_occt() {
    // If MMFORGE_SHIM_DIR is set and the shim archive exists, set occt_found.
    // Otherwise, search common paths (same as mmforge-geometry build.rs).
    let shim_dir = if let Some(dir) = std::env::var_os("MMFORGE_SHIM_DIR") {
        std::path::PathBuf::from(dir)
    } else if let Some(dir) = find_shim_library() {
        dir
    } else {
        return;
    };

    let shim_lib = shim_dir.join("libmmforge_occt_shim.a");
    if shim_lib.is_file() {
        println!("cargo:rustc-cfg=occt_found");
    }
}

#[cfg(feature = "occt")]
fn find_shim_library() -> Option<std::path::PathBuf> {
    let manifest_dir =
        std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default());

    let candidates: Vec<std::path::PathBuf> = vec![
        manifest_dir.join("../mmforge-geometry/shim/build/lib"),
        manifest_dir.join("../mmforge-geometry/shim/build"),
        manifest_dir.join("../../target/shim/lib"),
        std::path::PathBuf::from("/usr/local/lib"),
        std::path::PathBuf::from("/opt/homebrew/lib"),
    ];

    for dir in &candidates {
        if dir.join("libmmforge_occt_shim.a").is_file() {
            return Some(dir.clone());
        }
    }
    None
}

//! Build script for mmforge-format-step.
//!
//! When the `occt` feature is enabled, verifies that:
//!
//! 1. OCCT include/lib directories are located (env vars or pkg-config).
//! 2. The shim library (`libmmforge_occt_shim.a`) is found.
//! 3. The shim is a valid ar archive exporting all required symbols.
//!
//! Only then sets `occt_found`.  Link directives are emitted by
//! mmforge-geometry's build.rs — this crate only needs the cfg flag.
//!
//! **Important**: if OCCT dirs are not found (no env vars, pkg-config
//! fails), `occt_found` is NOT set even if the shim file exists on
//! disk (e.g. stale `shim/build/` artifacts).  This prevents link
//! failures when OCCT is not installed.

fn main() {
    println!("cargo:rerun-if-env-changed=OCCT_INCLUDE_DIR");
    println!("cargo:rerun-if-env-changed=OCCT_LIB_DIR");
    println!("cargo:rerun-if-env-changed=MMFORGE_SHIM_DIR");
    println!("cargo:rerun-if-changed=build.rs");

    println!("cargo::rustc-check-cfg=cfg(occt_found)");

    #[cfg(feature = "occt")]
    detect_occt();
}

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

/// Symbols that must be exported by the shim (same list as
/// mmforge-geometry/build.rs).
#[cfg(feature = "occt")]
const REQUIRED_SHIM_SYMBOLS: &[&str] = &[
    "mmforge_abi_version",
    "mmforge_step_reader_new",
    "mmforge_step_reader_read_file",
    "mmforge_step_reader_transfer_roots",
    "mmforge_step_reader_root_count",
    "mmforge_step_reader_get_root",
    "mmforge_step_reader_warning_count",
    "mmforge_step_reader_get_warning",
    "mmforge_step_reader_free",
    "mmforge_shape_type",
    "mmforge_shape_bbox",
    "mmforge_shape_label",
    "mmforge_shape_free",
    "mmforge_tessellate_shape",
    "mmforge_mesh_vertex_count",
    "mmforge_mesh_triangle_count",
    "mmforge_mesh_positions",
    "mmforge_mesh_normals",
    "mmforge_mesh_indices",
    "mmforge_mesh_bbox",
    "mmforge_mesh_free",
    "mmforge_occt_version",
];

#[cfg(feature = "occt")]
fn detect_occt() {
    // Step 1: Verify OCCT directories exist.
    if !occt_dirs_found() {
        return;
    }

    // Step 2: Locate shim library.
    let shim_dir = if let Some(dir) = std::env::var_os("MMFORGE_SHIM_DIR") {
        std::path::PathBuf::from(dir)
    } else if let Some(dir) = find_shim_library() {
        dir
    } else {
        return;
    };

    let shim_lib = shim_dir.join("libmmforge_occt_shim.a");

    // Step 3: Validate shim archive (ar magic + nm symbol check).
    if validate_shim(&shim_lib).is_ok() {
        println!("cargo:rustc-cfg=occt_found");
    }
}

// ---------------------------------------------------------------------------
// OCCT directory check (no link output — just existence)
// ---------------------------------------------------------------------------

/// Check that OCCT include/lib directories exist.
/// Tries env vars first, then pkg-config.
#[cfg(feature = "occt")]
fn occt_dirs_found() -> bool {
    let inc = std::env::var_os("OCCT_INCLUDE_DIR");
    let lib = std::env::var_os("OCCT_LIB_DIR");

    match (inc, lib) {
        (Some(inc), Some(lib)) => {
            std::path::Path::new(&inc).is_dir() && std::path::Path::new(&lib).is_dir()
        }
        (None, None) => pkg_config_finds_opencascade(),
        _ => false, // Both must be set, or neither.
    }
}

#[cfg(feature = "occt")]
fn pkg_config_finds_opencascade() -> bool {
    pkg_config::Config::new()
        .atleast_version("7.5")
        .probe("OpenCASCADE")
        .is_ok()
}

// ---------------------------------------------------------------------------
// Shim discovery
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Shim validation (ar magic + nm symbols)
// ---------------------------------------------------------------------------

/// Validate that `path` is a real ar archive exporting all required symbols.
#[cfg(feature = "occt")]
fn validate_shim(path: &std::path::Path) -> Result<(), String> {
    // 1. Readable + non-empty.
    match std::fs::metadata(path) {
        Ok(m) if m.len() == 0 => {
            return Err(format!("shim at '{}' is empty", path.display()));
        }
        Ok(_) => {}
        Err(e) => return Err(format!("cannot read shim at '{}': {e}", path.display())),
    }

    // 2. Ar magic.
    let mut magic = [0u8; 8];
    std::fs::File::open(path)
        .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut magic))
        .map_err(|e| format!("cannot read header of '{}': {e}", path.display()))?;
    if magic != *b"!<arch>\n" {
        return Err(format!(
            "shim at '{}' is not a valid ar archive",
            path.display()
        ));
    }

    // 3. Required symbols via nm.
    let defined = nm_defined_symbols(path)?;
    let missing: Vec<&str> = REQUIRED_SHIM_SYMBOLS
        .iter()
        .copied()
        .filter(|sym| !defined.contains(*sym))
        .collect();

    if missing.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "shim at '{}' missing symbols: {}",
            path.display(),
            missing.join(", ")
        ))
    }
}

/// Run nm and return the set of defined global symbols.
#[cfg(feature = "occt")]
fn nm_defined_symbols(path: &std::path::Path) -> Result<std::collections::HashSet<String>, String> {
    let configs: &[(&str, &[&str])] = &[
        ("nm", &["-gjU"]),
        ("nm", &["-g", "--defined-only"]),
        ("llvm-nm", &["-g", "--defined-only"]),
    ];

    for (tool, args) in configs {
        let output = match std::process::Command::new(tool)
            .args(*args)
            .arg(path)
            .output()
        {
            Ok(o) if o.status.success() => o,
            _ => continue,
        };

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut symbols = std::collections::HashSet::new();
        for line in stdout.lines() {
            if let Some(name) = line.split_whitespace().last() {
                let name = name.strip_prefix('_').unwrap_or(name);
                symbols.insert(name.to_string());
            }
        }
        return Ok(symbols);
    }

    Err("no working nm tool found".to_string())
}

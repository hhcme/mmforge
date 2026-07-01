//! Build script for mmforge-geometry.
//!
//! # `occt_found` cfg
//!
//! The `occt_found` cfg is ONLY set when **all** of the following hold:
//!
//! 1. The `occt` Cargo feature is enabled.
//! 2. OCCT include/lib directories are located (env vars or pkg-config).
//! 3. The mmforge OCCT shim library (`libmmforge_occt_shim.a`) is found
//!    **and** passes `nm`-based symbol verification:
//!    - File exists, is non-empty, and has ar magic (`!<arch>\n`).
//!    - `nm` (or `llvm-nm`) confirms **all** 14 required symbols are
//!      defined (T/t/D/d sections).  A partial shim that is missing even
//!      one symbol is rejected.
//!    - `mmforge_abi_version` is included so the Rust side can do a
//!      runtime ABI-compatibility check (catches stale shims that pass
//!      nm symbol-name validation but have incompatible signatures).
//!
//! Only then does `build.rs` emit **any** `rustc-link-search` or
//! `rustc-link-lib` directives — for both the shim **and** the OCCT
//! libraries.  Before that point, nothing is emitted to the linker.
//!
//! Rationale: emitting OCCT link flags before verifying the shim would
//! cause linker errors (undefined symbols from the shim) on machines
//! where OCCT is installed but the shim is not yet built.
//!
//! # Detection strategies for OCCT dirs
//!
//! 1. `OCCT_INCLUDE_DIR` + `OCCT_LIB_DIR` env vars (both required,
//!    both must be existing directories).
//! 2. `pkg-config` (`OpenCASCADE` >= 7.5).
//!
//! Then, `MMFORGE_SHIM_DIR` env var points to a directory containing
//! the pre-built shim static library (`libmmforge_occt_shim.a`).

fn main() {
    println!("cargo:rerun-if-env-changed=OCCT_INCLUDE_DIR");
    println!("cargo:rerun-if-env-changed=OCCT_LIB_DIR");
    println!("cargo:rerun-if-env-changed=OCCT_LIBS");
    println!("cargo:rerun-if-env-changed=MMFORGE_SHIM_DIR");
    println!("cargo:rerun-if-changed=build.rs");

    // Declare occt_found as a valid cfg.
    println!("cargo::rustc-check-cfg=cfg(occt_found)");

    #[cfg(feature = "occt")]
    detect_occt();
}

// ---------------------------------------------------------------------------
// Collected OCCT location data (no link directives emitted yet)
// ---------------------------------------------------------------------------

/// Holds the located OCCT paths and library names.
/// No `cargo:rustc-link-*` directives are emitted at this stage.
#[cfg(feature = "occt")]
struct OcctInfo {
    inc_dir: std::path::PathBuf,
    lib_dir: std::path::PathBuf,
    libs: Vec<String>,
}

// ---------------------------------------------------------------------------
// Main detection flow
// ---------------------------------------------------------------------------

#[cfg(feature = "occt")]
fn detect_occt() {
    // --- Step 1: Locate OCCT directories (collect only, no link output) ---
    let occt_info = match locate_occt() {
        Some(info) => info,
        None => {
            println!(
                "cargo:warning=OCCT not found. Set OCCT_INCLUDE_DIR + OCCT_LIB_DIR, \
                 or install OpenCASCADE with pkg-config support."
            );
            return;
        }
    };

    // --- Step 2: Locate the shim library ---
    // Priority: MMFORGE_SHIM_DIR env var → auto-detect common paths.
    let shim_dir = if let Some(dir) = std::env::var_os("MMFORGE_SHIM_DIR") {
        std::path::PathBuf::from(dir)
    } else if let Some(dir) = find_shim_library() {
        dir
    } else {
        println!(
            "cargo:warning=OCCT dirs found but libmmforge_occt_shim.a not found. \
             Build crates/mmforge-geometry/shim/ with CMake, or set MMFORGE_SHIM_DIR. \
             Using stubs for now."
        );
        return;
    };

    let shim_lib = shim_dir.join("libmmforge_occt_shim.a");

    // --- Shim validation: must be a valid ar archive exporting required symbols ---
    match validate_shim_archive(&shim_lib) {
        Ok(()) => {}
        Err(reason) => {
            println!("cargo:warning={reason}. Using stubs.");
            return;
        }
    }

    // --- Boundary validation: OCCT lib dir must contain at least one expected lib ---
    let first_lib = occt_info
        .libs
        .first()
        .map(|l| format!("lib{l}.so"))
        .unwrap_or_default();
    if !first_lib.is_empty() {
        // Check for any common shared-lib extension; we don't know the
        // platform suffix at build-script time, so just check the dir is
        // non-empty (at least one file exists).
        let lib_dir_entries = std::fs::read_dir(&occt_info.lib_dir)
            .ok()
            .and_then(|mut d| d.next())
            .and_then(|e| e.ok());
        if lib_dir_entries.is_none() {
            println!(
                "cargo:warning=OCCT_LIB_DIR='{}' is empty — no library files found. \
                 Using stubs.",
                occt_info.lib_dir.display()
            );
            return;
        }
    }

    // --- All checks passed: emit link directives and set occt_found ---

    // OCCT include path (for C++ headers consumed by the shim build).
    println!("cargo:include={}", occt_info.inc_dir.display());

    // OCCT library search path + libs.
    println!(
        "cargo:rustc-link-search=native={}",
        occt_info.lib_dir.display()
    );
    for lib in &occt_info.libs {
        println!("cargo:rustc-link-lib={lib}");
    }

    // Shim library (C++ static library — link C++ runtime).
    println!("cargo:rustc-link-search=native={}", shim_dir.display());
    println!("cargo:rustc-link-lib=static=mmforge_occt_shim");
    if cfg!(target_os = "macos") {
        println!("cargo:rustc-link-lib=c++");
    } else {
        println!("cargo:rustc-link-lib=stdc++");
    }

    // Enable real FFI.
    println!("cargo:rustc-cfg=occt_found");
    println!(
        "cargo:warning=OCCT shim verified at {}. Real FFI enabled.",
        shim_dir.display()
    );
}

// ---------------------------------------------------------------------------
// OCCT directory location (collect only — no link directives)
// ---------------------------------------------------------------------------

/// Try to locate OCCT include/lib dirs.
/// Returns `Some(OcctInfo)` with collected paths — **no** `cargo:rustc-link-*`
/// directives are emitted.  Returns `None` if OCCT cannot be located.
#[cfg(feature = "occt")]
fn locate_occt() -> Option<OcctInfo> {
    let inc_dir = std::env::var_os("OCCT_INCLUDE_DIR");
    let lib_dir = std::env::var_os("OCCT_LIB_DIR");

    match (inc_dir, lib_dir) {
        (Some(inc), Some(lib)) => {
            let inc_path = std::path::PathBuf::from(&inc);
            let lib_path = std::path::PathBuf::from(&lib);

            if inc_path.is_dir() && lib_path.is_dir() {
                let libs = parse_occt_libs();
                Some(OcctInfo {
                    inc_dir: inc_path,
                    lib_dir: lib_path,
                    libs,
                })
            } else {
                let mut reasons = Vec::new();
                if !inc_path.is_dir() {
                    reasons.push(format!(
                        "OCCT_INCLUDE_DIR='{}' is not a directory",
                        inc_path.display()
                    ));
                }
                if !lib_path.is_dir() {
                    reasons.push(format!(
                        "OCCT_LIB_DIR='{}' is not a directory",
                        lib_path.display()
                    ));
                }
                println!(
                    "cargo:warning=OCCT env vars set but invalid: {}. \
                     Falling back to pkg-config.",
                    reasons.join("; ")
                );
                try_pkg_config()
            }
        }
        (Some(_), None) | (None, Some(_)) => {
            println!(
                "cargo:warning=OCCT_INCLUDE_DIR and OCCT_LIB_DIR must \
                 both be set. Only one was provided. Falling back to pkg-config."
            );
            try_pkg_config()
        }
        (None, None) => try_pkg_config(),
    }
}

/// Parse the OCCT_LIBS env var (semicolon-separated) or return the default
/// minimum set for STEP parsing.
#[cfg(feature = "occt")]
fn parse_occt_libs() -> Vec<String> {
    let raw = std::env::var("OCCT_LIBS").unwrap_or_else(|_| {
        "TKernel;TKMath;TKG3d;TKBRep;TKTopAlgo;TKGeomAlgo;TKGeomBase;TKShHealing;TKMesh;TKBO;TKBool;TKXSBase;TKDESTEP;TKDEIGES;TKXCAF;TKCAF;TKCDF;TKLCAF;TKStd;TKStdL;TKXmlXCAF;TKService".to_string()
    });
    raw.split(';')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Try pkg-config detection.  Returns `Some(OcctInfo)` with collected paths
/// — **no** `cargo:rustc-link-*` directives are emitted.
#[cfg(feature = "occt")]
fn try_pkg_config() -> Option<OcctInfo> {
    match pkg_config::Config::new()
        .atleast_version("7.5")
        .probe("OpenCASCADE")
    {
        Ok(lib) => {
            let inc_dir = lib
                .include_paths
                .first()
                .cloned()
                .unwrap_or_else(|| std::path::PathBuf::from("/usr/include"));

            // pkg-config already provides lib paths and names; we collect them.
            let lib_dir = lib
                .link_paths
                .first()
                .cloned()
                .unwrap_or_else(|| std::path::PathBuf::from("/usr/lib"));
            let libs = lib.libs;

            Some(OcctInfo {
                inc_dir,
                lib_dir,
                libs,
            })
        }
        Err(_) => None,
    }
}

// ---------------------------------------------------------------------------
// Shim auto-detection
// ---------------------------------------------------------------------------

/// Search common paths for `libmmforge_occt_shim.a`.
/// Returns the parent directory if found, `None` otherwise.
#[cfg(feature = "occt")]
fn find_shim_library() -> Option<std::path::PathBuf> {
    let manifest_dir =
        std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default());

    let candidates: Vec<std::path::PathBuf> = vec![
        // CMake default build output (with install prefix)
        manifest_dir.join("shim/build/lib"),
        // CMake build directory (no install)
        manifest_dir.join("shim/build"),
        // Cargo workspace target directory
        manifest_dir.join("../target/shim/lib"),
        // System-wide installs
        std::path::PathBuf::from("/usr/local/lib"),
        std::path::PathBuf::from("/opt/homebrew/lib"),
    ];

    for dir in &candidates {
        let lib = dir.join("libmmforge_occt_shim.a");
        if lib.is_file() {
            return Some(dir.clone());
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Shim archive validation
// ---------------------------------------------------------------------------

/// Symbols that **must** be exported by `libmmforge_occt_shim.a`.
///
/// This list is the union of **every** `extern "C"` function declared in
/// `sys.rs` inside `#[cfg(occt_found)]` blocks.  A partial shim that
/// exports only a subset will be rejected — the adapter references all
/// of them, so a missing symbol would cause a linker error.
///
/// When adding a new `extern "C"` to `sys.rs`, add the symbol name here
/// as well.  The link-probe test in `adapter.rs` enforces this at test
/// time.
#[cfg(feature = "occt")]
const REQUIRED_SHIM_SYMBOLS: &[&str] = &[
    // C ABI version (runtime check against stale shim)
    "mmforge_abi_version",
    // STEPControl_Reader
    "mmforge_step_reader_new",
    "mmforge_step_reader_read_file",
    "mmforge_step_reader_transfer_roots",
    "mmforge_step_reader_root_count",
    "mmforge_step_reader_get_root",
    "mmforge_step_reader_warning_count",
    "mmforge_step_reader_get_warning",
    "mmforge_step_reader_free",
    // IGESControl_Reader
    "mmforge_iges_reader_new",
    "mmforge_iges_reader_read_file",
    "mmforge_iges_reader_transfer_roots",
    "mmforge_iges_reader_root_count",
    "mmforge_iges_reader_get_root",
    "mmforge_iges_reader_warning_count",
    "mmforge_iges_reader_get_warning",
    "mmforge_iges_reader_free",
    "mmforge_iges_shape_type",
    "mmforge_iges_shape_bbox",
    "mmforge_iges_shape_label",
    // TopoDS_Shape
    "mmforge_shape_type",
    "mmforge_shape_bbox",
    "mmforge_shape_label",
    "mmforge_shape_free",
    // Tessellation
    "mmforge_tessellate_shape",
    "mmforge_mesh_vertex_count",
    "mmforge_mesh_triangle_count",
    "mmforge_mesh_positions",
    "mmforge_mesh_normals",
    "mmforge_mesh_indices",
    "mmforge_mesh_bbox",
    "mmforge_mesh_free",
    // Version
    "mmforge_occt_version",
];

/// Validate that `path` is a real ar archive and exports **all**
/// [`REQUIRED_SHIM_SYMBOLS`] as verified by `nm`.
///
/// Checks performed (in order, fail-fast):
///
/// 1. File exists and is non-empty.
/// 2. Starts with the ar magic `!<arch>\n` (8 bytes).
/// 3. `nm` (or `llvm-nm`) lists all required symbols as defined
///    (type T/t/D/d/b on macOS/Linux).
#[cfg(feature = "occt")]
fn validate_shim_archive(path: &std::path::Path) -> Result<(), String> {
    // 1. Readability + non-empty.
    match std::fs::metadata(path) {
        Ok(m) if m.len() == 0 => {
            return Err(format!(
                "libmmforge_occt_shim.a at '{}' is empty (0 bytes)",
                path.display()
            ));
        }
        Ok(_) => {}
        Err(e) => {
            return Err(format!(
                "Cannot read libmmforge_occt_shim.a at '{}': {e}",
                path.display()
            ));
        }
    }

    // 2. Ar magic: "!<arch>\n" (8 bytes).
    let mut magic = [0u8; 8];
    match std::fs::File::open(path).and_then(|mut f| std::io::Read::read_exact(&mut f, &mut magic))
    {
        Ok(()) if magic == *b"!<arch>\n" => {}
        Ok(()) => {
            return Err(format!(
                "libmmforge_occt_shim.a at '{}' is not a valid ar archive \
                 (bad magic header)",
                path.display()
            ));
        }
        Err(e) => {
            return Err(format!("Cannot read header of '{}': {e}", path.display()));
        }
    }

    // 3. Symbol verification via nm.
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
            "libmmforge_occt_shim.a at '{}' is missing required symbols: {}. \
             Rebuild the shim library.",
            path.display(),
            missing.join(", ")
        ))
    }
}

/// Run `nm` (or `llvm-nm`) on an archive and return the set of defined
/// global symbols (normalised: leading `_` stripped for macOS C-ABI
/// compatibility).
///
/// Tries the following tools in order:
///
/// 1. `nm -gjU` — macOS system nm (global, defined only, no undefined)
/// 2. `nm -g --defined-only` — GNU nm (Linux / Homebrew)
/// 3. `llvm-nm -g --defined-only` — LLVM nm (cross-platform fallback)
#[cfg(feature = "occt")]
fn nm_defined_symbols(path: &std::path::Path) -> Result<std::collections::HashSet<String>, String> {
    let nm_configs: &[(&str, &[&str])] = &[
        // macOS nm: -g (global), -j (no section name), -U (no undefined)
        ("nm", &["-gjU"]),
        // GNU nm: -g (global), --defined-only (skip undefined)
        ("nm", &["-g", "--defined-only"]),
        // LLVM nm: same flags as GNU
        ("llvm-nm", &["-g", "--defined-only"]),
    ];

    let mut last_err = String::new();

    for (tool, args) in nm_configs {
        let output = match std::process::Command::new(tool)
            .args(*args)
            .arg(path)
            .output()
        {
            Ok(o) if o.status.success() => o,
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                last_err = format!("{tool} failed (exit {}): {}", o.status, stderr.trim());
                continue;
            }
            Err(e) => {
                last_err = format!("Cannot run {tool}: {e}");
                continue;
            }
        };

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut symbols = std::collections::HashSet::new();

        for line in stdout.lines() {
            // nm output formats:
            //   macOS:  "0000000000000120 T _mmforge_step_reader_new"
            //   GNU:    "0000000000000120 T mmforge_step_reader_new"
            // We want the symbol name (last whitespace-delimited field).
            if let Some(name) = line.split_whitespace().last() {
                // Strip leading `_` (macOS C-ABI convention).
                let name = name.strip_prefix('_').unwrap_or(name);
                symbols.insert(name.to_string());
            }
        }

        return Ok(symbols);
    }

    Err(format!(
        "No working nm tool found (tried nm, llvm-nm). \
         Last error: {last_err}"
    ))
}

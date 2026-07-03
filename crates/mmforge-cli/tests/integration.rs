//! Process-level integration tests for `mmforge` CLI binary.
//!
//! These tests fork the compiled binary and assert on stdout, stderr, and
//! exit codes — verifying the full end-to-end behaviour that unit tests
//! cannot cover (exit codes, JSON output formatting, error messages).

use std::io::Write;
use std::process::Command;

/// Returns the path to the compiled `mmforge` binary.
fn mmforge_bin() -> std::path::PathBuf {
    std::env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("mmforge")
}

fn temp_stl(triangles: u32) -> tempfile::NamedTempFile {
    let mut f = tempfile::Builder::new().suffix(".stl").tempfile().unwrap();
    let mut data = vec![0u8; 80];
    data[..9].copy_from_slice(b"binarystl");
    data.extend_from_slice(&triangles.to_le_bytes());
    for _ in 0..triangles {
        // normal (0,0,1)
        data.extend_from_slice(&[0u8; 12]);
        // v0 (0,0,0)
        data.extend_from_slice(&0.0f32.to_le_bytes());
        data.extend_from_slice(&0.0f32.to_le_bytes());
        data.extend_from_slice(&0.0f32.to_le_bytes());
        // v1 (1,0,0)
        data.extend_from_slice(&1.0f32.to_le_bytes());
        data.extend_from_slice(&0.0f32.to_le_bytes());
        data.extend_from_slice(&0.0f32.to_le_bytes());
        // v2 (0,1,0)
        data.extend_from_slice(&0.0f32.to_le_bytes());
        data.extend_from_slice(&1.0f32.to_le_bytes());
        data.extend_from_slice(&0.0f32.to_le_bytes());
        // attribute
        data.extend_from_slice(&0u16.to_le_bytes());
    }
    f.write_all(&data).unwrap();
    f
}

// ----------------------------------------------------------------
// Exit code tests
// ----------------------------------------------------------------

#[test]
fn version_exit_zero() {
    let out = Command::new(mmforge_bin()).arg("version").output().unwrap();
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("mmforge"));
}

#[test]
fn info_stl_exit_zero() {
    let stl = temp_stl(1);
    let out = Command::new(mmforge_bin())
        .args(["info", stl.path().to_str().unwrap()])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "info should exit 0, stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn info_nonexistent_exit_nonzero() {
    let out = Command::new(mmforge_bin())
        .args(["info", "/tmp/mmforge_nonexistent_12345.stl"])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("error"), "stderr: {stderr}");
}

/// Round-trip: convert STL → LSM, then info the LSM.
#[test]
fn convert_then_info_lsm_exit_zero() {
    let stl = temp_stl(1);
    let lsm_path = stl.path().with_extension("lsm");

    let cvt = Command::new(mmforge_bin())
        .args([
            "convert",
            stl.path().to_str().unwrap(),
            "-o",
            lsm_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        cvt.status.success(),
        "convert failed: {}",
        String::from_utf8_lossy(&cvt.stderr)
    );

    let info = Command::new(mmforge_bin())
        .args(["info", lsm_path.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(
        info.status.success(),
        "lsm info failed: {}",
        String::from_utf8_lossy(&info.stderr)
    );
    let stdout = String::from_utf8_lossy(&info.stdout);
    assert!(
        stdout.contains("STL"),
        "expected source_format=STL, got: {stdout}"
    );
    assert!(
        stdout.contains("triangles: 1"),
        "expected 1 triangle, got: {stdout}"
    );
}

/// LSM with bad magic returns non-zero exit.
#[test]
fn lsm_bad_magic_exit_nonzero() {
    let mut f = tempfile::Builder::new().suffix(".lsm").tempfile().unwrap();
    f.write_all(b"XXXXjunk").unwrap();

    let out = Command::new(mmforge_bin())
        .args(["info", f.path().to_str().unwrap()])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("bad magic"), "stderr: {stderr}");
}

/// LSM with unsupported version returns non-zero exit.
#[test]
fn lsm_high_version_exit_nonzero() {
    let mut f = tempfile::Builder::new().suffix(".lsm").tempfile().unwrap();
    let mut data = vec![0u8; 100];
    data[0..4].copy_from_slice(b"LSMD");
    data[4] = 99; // version 99
    f.write_all(&data).unwrap();

    let out = Command::new(mmforge_bin())
        .args(["info", f.path().to_str().unwrap()])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("unsupported version"), "stderr: {stderr}");
}

// ----------------------------------------------------------------
// JSON output tests
// ----------------------------------------------------------------

#[test]
fn info_json_output_stable() {
    let stl = temp_stl(1);
    let out = Command::new(mmforge_bin())
        .args(["info", stl.path().to_str().unwrap(), "--format", "json"])
        .output()
        .unwrap();
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("\"source_format\""),
        "missing key, stdout: {stdout}"
    );

    let v: serde_json::Value = serde_json::from_str(&stdout).expect("should be valid JSON");
    assert_eq!(v["triangle_count"], 1);
    assert!(v["bounds"]["min"].is_array());
}

#[test]
fn validate_json_output_stable() {
    let stl = temp_stl(1);
    let out = Command::new(mmforge_bin())
        .args(["validate", stl.path().to_str().unwrap(), "--format", "json"])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "validate failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("\"valid\""),
        "missing valid key, stdout: {stdout}"
    );

    let parsed: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(parsed["valid"], true);
}

#[test]
fn benchmark_json_output_stable() {
    let stl = temp_stl(1);
    let out = Command::new(mmforge_bin())
        .args([
            "benchmark",
            stl.path().to_str().unwrap(),
            "-i",
            "2",
            "--format",
            "json",
        ])
        .output()
        .unwrap();
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("\"parse_ms_min\""), "stdout: {stdout}");
    assert!(stdout.contains("\"parse_ms_avg\""), "stdout: {stdout}");

    let _: serde_json::Value =
        serde_json::from_str(&stdout).expect("benchmark output should be valid JSON");
}

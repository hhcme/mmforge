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

// ----------------------------------------------------------------
// LSMC compressed format tests
// ----------------------------------------------------------------

#[test]
fn convert_to_lsmc_then_info_exit_zero() {
    let stl = temp_stl(1);
    let lsmc_path = stl.path().with_extension("lsmc");

    let cvt = Command::new(mmforge_bin())
        .args([
            "convert",
            stl.path().to_str().unwrap(),
            "--compress",
            "zstd",
            "-o",
            lsmc_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        cvt.status.success(),
        "convert to lsmc failed: {}",
        String::from_utf8_lossy(&cvt.stderr)
    );

    let info = Command::new(mmforge_bin())
        .args(["info", lsmc_path.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(
        info.status.success(),
        "lsmc info failed: {}",
        String::from_utf8_lossy(&info.stderr)
    );
    let stdout = String::from_utf8_lossy(&info.stdout);
    assert!(stdout.contains("STL"));
    assert!(stdout.contains("triangles: 1"));
}

#[test]
fn convert_to_lsmc_then_validate_json() {
    let stl = temp_stl(1);
    let lsmc_path = stl.path().with_extension("lsmc");

    Command::new(mmforge_bin())
        .args([
            "convert",
            stl.path().to_str().unwrap(),
            "--compress",
            "zstd",
            "-o",
            lsmc_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();

    let out = Command::new(mmforge_bin())
        .args(["validate", lsmc_path.to_str().unwrap(), "--format", "json"])
        .output()
        .unwrap();
    assert!(out.status.success());
    let v: serde_json::Value = serde_json::from_str(&String::from_utf8_lossy(&out.stdout)).unwrap();
    assert_eq!(v["valid"], true);
    assert_eq!(v["triangle_count"], 1);
}

#[test]
fn lsmc_bad_magic_exit_nonzero() {
    let mut f = tempfile::Builder::new().suffix(".lsmc").tempfile().unwrap();
    f.write_all(b"XXXXjunkcompress").unwrap();
    let out = Command::new(mmforge_bin())
        .args(["info", f.path().to_str().unwrap()])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("bad magic") || stderr.contains("error"),
        "stderr: {stderr}"
    );
}

#[test]
fn source_to_lsmc_to_info_json_round_trip() {
    let stl = temp_stl(2);
    let lsmc_path = stl.path().with_extension("lsmc");

    Command::new(mmforge_bin())
        .args([
            "convert",
            stl.path().to_str().unwrap(),
            "--compress",
            "zstd",
            "-o",
            lsmc_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();

    let out = Command::new(mmforge_bin())
        .args(["info", lsmc_path.to_str().unwrap(), "--format", "json"])
        .output()
        .unwrap();
    assert!(out.status.success());
    let v: serde_json::Value = serde_json::from_str(&String::from_utf8_lossy(&out.stdout)).unwrap();
    assert_eq!(v["triangle_count"], 2);
    assert_eq!(v["source_format"], "STL");
    assert!(v["bounds"]["min"].is_array());
}

#[test]
fn unknown_compress_method_rejected() {
    let stl = temp_stl(1);
    let out = Command::new(mmforge_bin())
        .args(["convert", stl.path().to_str().unwrap(), "--compress", "lz4"])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("unknown compression method"),
        "stderr: {stderr}"
    );
}

#[test]
fn lsmc_extension_corrupt_lsmc_rejected() {
    let mut f = tempfile::Builder::new().suffix(".lsmc").tempfile().unwrap();
    f.write_all(b"LSMDjunk").unwrap();
    let out = Command::new(mmforge_bin())
        .args(["info", f.path().to_str().unwrap()])
        .output()
        .unwrap();
    assert!(!out.status.success());
}

#[test]
fn lsmc_magic_in_any_extension_reads() {
    let stl = temp_stl(1);
    let lsmc = stl.path().with_extension("lsmc");
    Command::new(mmforge_bin())
        .args([
            "convert",
            stl.path().to_str().unwrap(),
            "-o",
            lsmc.to_str().unwrap(),
            "--compress",
            "zstd",
        ])
        .output()
        .unwrap();
    // Rename to a non-standard extension — magic detection must still work.
    let data = stl.path().with_extension("data");
    std::fs::rename(&lsmc, &data).unwrap();
    let out = Command::new(mmforge_bin())
        .args(["info", data.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("STL"));
}

/// .lsmc extension MUST be LSMC magic — valid .lsm renamed to .lsmc is rejected.
#[test]
fn lsmc_extension_rejects_plain_lsm_data() {
    let stl = temp_stl(1);
    let lsm = stl.path().with_extension("lsm");
    Command::new(mmforge_bin())
        .args([
            "convert",
            stl.path().to_str().unwrap(),
            "-o",
            lsm.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    let lsmc = stl.path().with_extension("lsmc");
    std::fs::rename(&lsm, &lsmc).unwrap();
    let out = Command::new(mmforge_bin())
        .args(["info", lsmc.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(
        !out.status.success(),
        "plain .lsm renamed to .lsmc must fail"
    );
}

/// No extension but LSMC magic must be read transparently.
#[test]
fn no_extension_lsmc_magic_reads() {
    let stl = temp_stl(1);
    let lsmc = stl.path().with_extension("lsmc");
    Command::new(mmforge_bin())
        .args([
            "convert",
            stl.path().to_str().unwrap(),
            "-o",
            lsmc.to_str().unwrap(),
            "--compress",
            "zstd",
        ])
        .output()
        .unwrap();
    let noext = stl.path().parent().unwrap().join("noext_test");
    std::fs::rename(&lsmc, &noext).unwrap();
    let out = Command::new(mmforge_bin())
        .args(["info", noext.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(String::from_utf8_lossy(&out.stdout).contains("STL"));
}

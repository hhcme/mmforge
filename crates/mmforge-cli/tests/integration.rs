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

/// LSMC magic detected in a file with non-standard extension reads correctly.
#[test]
fn lsmc_magic_in_unknown_extension_reads() {
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

/// --compress zstd with explicit .lsm output must error.
#[test]
fn compress_zstd_rejects_non_lsmc_output() {
    let stl = temp_stl(1);
    let lsm_path = stl.path().with_extension("lsm");
    let out = Command::new(mmforge_bin())
        .args([
            "convert",
            stl.path().to_str().unwrap(),
            "--compress",
            "zstd",
            "-o",
            lsm_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!out.status.success(), "--compress zstd -o .lsm must fail");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains(".lsmc") && stderr.contains("error"),
        "stderr: {stderr}"
    );
}

// ----------------------------------------------------------------
// Batch convert tests
// ----------------------------------------------------------------

#[test]
fn batch_convert_two_files_succeeds() {
    let a = temp_stl(1);
    let b = temp_stl(1);
    let out_dir = tempfile::tempdir().unwrap();

    let out = Command::new(mmforge_bin())
        .args([
            "batch-convert",
            "-o",
            out_dir.path().to_str().unwrap(),
            a.path().to_str().unwrap(),
            b.path().to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("2/2 converted"));
    let name1 = a.path().file_stem().unwrap().to_str().unwrap();
    let name2 = b.path().file_stem().unwrap().to_str().unwrap();
    assert!(out_dir.path().join(format!("{name1}.lsm")).exists());
    assert!(out_dir.path().join(format!("{name2}.lsm")).exists());
}

#[test]
fn batch_convert_compressed() {
    let a = temp_stl(1);
    let out_dir = tempfile::tempdir().unwrap();

    let out = Command::new(mmforge_bin())
        .args([
            "batch-convert",
            "-o",
            out_dir.path().to_str().unwrap(),
            "--compress",
            "zstd",
            a.path().to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("1/1 converted"));
    let name = a.path().file_stem().unwrap().to_str().unwrap();
    assert!(out_dir.path().join(format!("{name}.lsmc")).exists());
}

#[test]
fn batch_convert_json_summary() {
    let a = temp_stl(1);
    let out_dir = tempfile::tempdir().unwrap();

    let out = Command::new(mmforge_bin())
        .args([
            "batch-convert",
            "-o",
            out_dir.path().to_str().unwrap(),
            "--format",
            "json",
            a.path().to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(out.status.success());
    let v: serde_json::Value = serde_json::from_str(&String::from_utf8_lossy(&out.stdout)).unwrap();
    assert_eq!(v["total"], 1);
    assert_eq!(v["converted"], 1);
    assert_eq!(v["failed"], 0);
    assert_eq!(v["results"][0]["status"], "ok");
}

#[test]
fn batch_convert_partial_failure_json() {
    let a = temp_stl(1);
    // Non-existent file
    let bad = a.path().parent().unwrap().join("nonexistent_xyz.stl");
    let out_dir = tempfile::tempdir().unwrap();

    let out = Command::new(mmforge_bin())
        .args([
            "batch-convert",
            "-o",
            out_dir.path().to_str().unwrap(),
            "--format",
            "json",
            "--continue-on-error",
            a.path().to_str().unwrap(),
            bad.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    // Should exit 1 due to partial failure
    assert!(!out.status.success());
    let v: serde_json::Value = serde_json::from_str(&String::from_utf8_lossy(&out.stdout)).unwrap();
    assert_eq!(v["total"], 2);
    assert_eq!(v["converted"], 1);
    assert_eq!(v["failed"], 1);
    assert_eq!(v["results"][0]["status"], "ok");
    assert_eq!(v["results"][1]["status"], "error");
}

/// Two files from different directories with same stem must trigger conflict.
#[test]
fn batch_convert_output_conflict_detected() {
    let a = temp_stl(1);
    // Create a second file with the same stem in a different dir.
    let sub = tempfile::tempdir().unwrap();
    let b_path = sub.path().join(a.path().file_name().unwrap());
    std::fs::copy(a.path(), &b_path).unwrap();
    let out_dir = tempfile::tempdir().unwrap();

    let out = Command::new(mmforge_bin())
        .args([
            "batch-convert",
            "-o",
            out_dir.path().to_str().unwrap(),
            a.path().to_str().unwrap(),
            b_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("CONFLICT"));
}

/// Zero inputs must exit non-zero and not create output dir.
#[test]
fn batch_convert_zero_inputs_exits_nonzero() {
    let out_dir = tempfile::tempdir().unwrap();
    // Start with empty dir, then remove it — batch-convert shouldn't recreate.
    let sub = out_dir.path().join("sub");
    let out = Command::new(mmforge_bin())
        .args(["batch-convert", "-o", sub.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(
        !sub.exists(),
        "output dir must not be created for zero inputs"
    );
}

/// --continue-on-error skips conflict items but converts the rest.
#[test]
fn batch_convert_continue_on_error_skips_conflicts() {
    let dir1 = tempfile::tempdir().unwrap();
    let dir2 = tempfile::tempdir().unwrap();
    let stl_data = {
        let f = temp_stl(1);
        std::fs::read(f.path()).unwrap()
    };
    let same = dir1.path().join("dup.stl");
    let dup = dir2.path().join("dup.stl");
    std::fs::write(&same, &stl_data).unwrap();
    std::fs::write(&dup, &stl_data).unwrap();
    let other = temp_stl(1);
    let out_dir = tempfile::tempdir().unwrap();

    let out = Command::new(mmforge_bin())
        .args([
            "batch-convert",
            "-o",
            out_dir.path().to_str().unwrap(),
            "--continue-on-error",
            "--format",
            "json",
            same.to_str().unwrap(),
            dup.to_str().unwrap(),
            other.path().to_str().unwrap(),
        ])
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let v: serde_json::Value = serde_json::from_str(&stdout).unwrap();
    assert!(!out.status.success(), "should exit 1 due to conflict");
    assert_eq!(v["conflicts"], 2);
    assert_eq!(v["converted"], 1);
}

/// Existing output file is treated as conflict.
#[test]
fn batch_convert_rejects_existing_output() {
    let a = temp_stl(1);
    let out_dir = tempfile::tempdir().unwrap();
    let name = a.path().file_stem().unwrap().to_str().unwrap();
    std::fs::write(out_dir.path().join(format!("{name}.lsm")), b"existing").unwrap();

    let out = Command::new(mmforge_bin())
        .args([
            "batch-convert",
            "-o",
            out_dir.path().to_str().unwrap(),
            "--format",
            "json",
            a.path().to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let v: serde_json::Value = serde_json::from_str(&String::from_utf8_lossy(&out.stdout)).unwrap();
    assert_eq!(v["conflicts"], 1);
    assert_eq!(v["converted"], 0);
    assert_eq!(v["results"][0]["status"], "conflict");
}

/// Default (no --continue-on-error) with conflict reports summary and exits 1.
#[test]
fn batch_convert_default_conflict_reports_json() {
    let dir1 = tempfile::tempdir().unwrap();
    let dir2 = tempfile::tempdir().unwrap();
    let stl_data = {
        let f = temp_stl(1);
        std::fs::read(f.path()).unwrap()
    };
    let same = dir1.path().join("dup.stl");
    let dup = dir2.path().join("dup.stl");
    std::fs::write(&same, &stl_data).unwrap();
    std::fs::write(&dup, &stl_data).unwrap();
    let out_dir = tempfile::tempdir().unwrap();

    let out = Command::new(mmforge_bin())
        .args([
            "batch-convert",
            "-o",
            out_dir.path().to_str().unwrap(),
            "--format",
            "json",
            same.to_str().unwrap(),
            dup.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let v: serde_json::Value = serde_json::from_str(&String::from_utf8_lossy(&out.stdout)).unwrap();
    assert_eq!(v["converted"], 0);
    assert_eq!(v["conflicts"], 2);
}

/// All inputs conflicted + --continue-on-error: must still produce
/// unified summary with every conflict result (not just an error message).
#[test]
fn batch_convert_all_conflicted_continue_on_error_produces_summary() {
    let dir1 = tempfile::tempdir().unwrap();
    let dir2 = tempfile::tempdir().unwrap();
    let stl_data = {
        let f = temp_stl(1);
        std::fs::read(f.path()).unwrap()
    };
    let same = dir1.path().join("dup.stl");
    let dup = dir2.path().join("dup.stl");
    std::fs::write(&same, &stl_data).unwrap();
    std::fs::write(&dup, &stl_data).unwrap();
    let out_dir = tempfile::tempdir().unwrap();

    let out = Command::new(mmforge_bin())
        .args([
            "batch-convert",
            "-o",
            out_dir.path().to_str().unwrap(),
            "--continue-on-error",
            "--format",
            "json",
            same.to_str().unwrap(),
            dup.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let v: serde_json::Value = serde_json::from_str(&String::from_utf8_lossy(&out.stdout)).unwrap();
    assert_eq!(v["total"], 2);
    assert_eq!(v["converted"], 0);
    assert_eq!(v["failed"], 0);
    assert_eq!(v["conflicts"], 2);
    assert_eq!(v["results"].as_array().unwrap().len(), 2);
    for r in v["results"].as_array().unwrap() {
        assert_eq!(r["status"], "conflict");
    }
}

/// Mixed input (1 conflict pair + 1 normal) without --continue-on-error:
/// non-conflicting input shows as SKIP, not FAIL.
#[test]
fn batch_convert_no_continue_skips_non_conflict_with_skip_status() {
    let dir1 = tempfile::tempdir().unwrap();
    let dir2 = tempfile::tempdir().unwrap();
    let stl_data = {
        let f = temp_stl(1);
        std::fs::read(f.path()).unwrap()
    };
    let same = dir1.path().join("dup.stl");
    let dup = dir2.path().join("dup.stl");
    std::fs::write(&same, &stl_data).unwrap();
    std::fs::write(&dup, &stl_data).unwrap();
    let other = temp_stl(1);
    let out_dir = tempfile::tempdir().unwrap();

    // Text output
    let out = Command::new(mmforge_bin())
        .args([
            "batch-convert",
            "-o",
            out_dir.path().to_str().unwrap(),
            same.to_str().unwrap(),
            dup.to_str().unwrap(),
            other.path().to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("SKIP"), "stdout: {stdout}");
    assert!(stdout.contains("CONFLICT"));
    assert!(!stdout.contains("FAIL"));
    assert!(stdout.contains("skipped"));

    // JSON output
    let out2 = Command::new(mmforge_bin())
        .args([
            "batch-convert",
            "-o",
            out_dir.path().to_str().unwrap(),
            "--format",
            "json",
            same.to_str().unwrap(),
            dup.to_str().unwrap(),
            other.path().to_str().unwrap(),
        ])
        .output()
        .unwrap();
    let v: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&out2.stdout)).unwrap();
    assert_eq!(v["total"], 3);
    assert_eq!(v["converted"], 0);
    assert_eq!(v["conflicts"], 2);
    assert_eq!(v["skipped"], 1);
}

// ----------------------------------------------------------------
// STEP/IGES JSON — stdout must always be valid JSON
// ----------------------------------------------------------------

#[test]
fn step_fixture_json_error_is_valid_json_on_stdout() {
    let step_fixture = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../mmforge-geometry/testdata/assembly.stp");
    if !step_fixture.exists() {
        eprintln!("SKIP: STEP fixture not found");
        return;
    }
    let out = Command::new(mmforge_bin())
        .args(["info", step_fixture.to_str().unwrap(), "--format", "json"])
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let v: serde_json::Value = serde_json::from_str(&stdout)
        .unwrap_or_else(|e| panic!("stdout not valid JSON: {e}\nstdout: {stdout}"));
    assert!(v.get("occt_available").is_some(), "missing occt_available");
    if let Some(err) = v.get("error") {
        assert!(!err.as_str().unwrap_or("").is_empty());
        assert_eq!(v["node_count"], 0);
        assert_eq!(v["triangle_count"], 0);
    } else {
        assert!(v["triangle_count"].as_u64().unwrap_or(0) > 0);
    }
}

#[test]
fn iges_fixture_json_error_is_valid_json_on_stdout() {
    let iges_fixture = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../mmforge-geometry/testdata/box.igs");
    if !iges_fixture.exists() {
        eprintln!("SKIP: IGES fixture not found");
        return;
    }
    let out = Command::new(mmforge_bin())
        .args(["info", iges_fixture.to_str().unwrap(), "--format", "json"])
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let v: serde_json::Value = serde_json::from_str(&stdout)
        .unwrap_or_else(|e| panic!("stdout not valid JSON: {e}\nstdout: {stdout}"));
    assert!(v.get("occt_available").is_some(), "missing occt_available");
    if let Some(err) = v.get("error") {
        assert!(!err.as_str().unwrap_or("").is_empty());
        assert_eq!(v["node_count"], 0);
        assert_eq!(v["triangle_count"], 0);
    } else {
        assert!(v["triangle_count"].as_u64().unwrap_or(0) > 0);
    }
}

#[test]
fn nonexistent_file_json_error_valid_json_on_stdout() {
    let out = Command::new(mmforge_bin())
        .args([
            "info",
            "/tmp/mmforge_nonexistent_12345.step",
            "--format",
            "json",
        ])
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let v: serde_json::Value = serde_json::from_str(&stdout)
        .unwrap_or_else(|e| panic!("stdout not valid JSON: {e}\nstdout: {stdout}"));
    assert!(v.get("error").is_some(), "must have error field");
    assert_eq!(v["node_count"], 0);
    assert_eq!(v["triangle_count"], 0);
    assert!(
        v.get("occt_available").is_some(),
        "must have occt_available"
    );
}

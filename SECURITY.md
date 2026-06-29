# Security Policy

MMForge is currently in a pre-alpha planning stage. There are no production releases yet.

## Reporting A Vulnerability

Please report security issues privately instead of opening a public issue.

Until a dedicated security contact is published, use GitHub's private vulnerability reporting feature if available on the repository. If private reporting is not available, open a minimal public issue that says a private security contact is needed, without disclosing exploit details.

## Scope

Security-sensitive areas include:

- Untrusted CAD/model file parsing
- Memory safety at Rust/C/C++ FFI boundaries
- Native rendering backends
- Decompression, archive, or embedded resource handling
- CLI file system access

## Expectations

When parser code lands, malformed and hostile input should be treated as expected input. Fuzzing, corpus tests, and clear error boundaries are strongly encouraged for all file format parsers.

## 中文说明

MMForge 当前仍处于 pre-alpha 规划阶段，尚无生产版本。

请不要在公开 issue 中披露漏洞细节。优先使用 GitHub 私有漏洞报告功能；如果仓库尚未开启该功能，可以创建一个不包含漏洞细节的公开 issue，请维护者提供私密联系方式。

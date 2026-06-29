# Contributing To MMForge

Thanks for your interest in MMForge.

The project is currently in the planning and architecture stage. The most useful contributions right now are requirement review, design feedback, format-specific notes, documentation fixes, and small prototypes that validate architecture decisions.

## Ways To Contribute

- Review docs for technical accuracy.
- Open issues for unclear requirements, missing formats, or architecture risks.
- Propose focused design changes with trade-offs.
- Add minimal examples or test assets that can be legally redistributed.
- Help shape parser, geometry, rendering, and FFI boundaries.

## Development Principles

- Keep the core Rust crates platform-agnostic.
- Keep GPL-bound functionality optional and clearly separated.
- Prefer explicit data contracts over implicit renderer/parser coupling.
- Document format limitations honestly.
- Optimize for correctness and inspectability before broad format coverage.

## Pull Requests

Before opening a pull request:

- Keep the change focused.
- Update documentation when behavior or architecture changes.
- Add tests when code is introduced.
- Include license information for new dependencies or sample assets.
- Avoid committing generated build artifacts.

## Commit Style

Use short, imperative commit messages when possible:

```text
Add LSM material schema draft
Document DWG license boundary
Fix STEP parser architecture typo
```

## License Of Contributions

Unless you explicitly state otherwise, any contribution submitted to MMForge is licensed under the same terms as the project: MIT OR Apache-2.0.

Do not submit code, assets, or sample CAD files unless you have the right to contribute them under a compatible license.

## 中文说明

欢迎参与 MMForge。

项目当前处于规划与架构设计阶段，最有价值的贡献包括需求审阅、架构反馈、格式专项设计建议、文档修正，以及用于验证架构的小型原型。

提交 PR 前请保持改动聚焦；涉及行为或架构变化时同步更新文档；新增代码时补充测试；新增依赖或示例资产时说明许可证；不要提交生成产物。

除非你明确声明，否则提交到 MMForge 的贡献将按项目相同条款发布：MIT OR Apache-2.0。

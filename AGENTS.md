# SDK development

Keep shared values, validation, deterministic planning and state in Rust. Keep native resources and language scheduling in their adapters. Hosts own product policy, permission prompts, persistence and UI.

Use Git on main. Preserve published commits and pinned dependencies; keep unfinished edits in the working tree and publish coherent main units without PRs.

Swift consumers install through Package.swift and tracked native frameworks. Rebuild native artifacts after Rust/C/input changes; maintain their provenance and runtime notices. Keep C ownership explicit and copy foreign views before invoking host callbacks. Test OS effects only in owned isolated fixtures and report actual runtime coverage separately from compilation.

Automatic macOS source checks run the shared Rust action contracts and strict Swift tests against the tracked framework with default pinned dependencies. Keep Rust and Swift WindowManagement pins aligned so the controller's captured private Git bundles resolve both. Native OS acceptance remains separate.

Use English documentation/comments. Use GitHub-hosted CI without private dependency credentials. Human QA/data and existing VM/security/sharing settings are protected. Read README.md and the affected API catalog before changing a contract. Contributor commands and validation live in README.md#development-and-validation.

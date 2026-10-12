# Shared Attendance Checks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan inline. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Execute one shared set of explicit workday expectations against the real Swift and C# cores on every relevant CI change.

**Architecture:** JSON contains schema 1, an IANA time zone and 17 cases with literal expected duration/arrival eligibility. Independent Swift and C# check executables load that same file and fail on any mismatch or incomplete fixture. Each existing platform CI runs its checker; shared fixtures and either Core trigger both workflows.

**Tech Stack:** Swift 6/Foundation, existing .NET 10/System.Text.Json, GitHub Actions.

**Spec:** `docs/PLATFORM-STATUS.md`, `docs/PLATFORM-VALIDATION.md`, GitHub issue #27.

## Global Constraints

- Keep one shared main and the existing feature/status table.
- Do not change production attendance rules, bundle identity/build, stored records, installed apps or prepared build 26.
- Use the existing SDKs; no new application dependencies or credentials.
- Expectations are hand-specified, never derived from either implementation.
- Local core success does not prove Windows GUI/session or Mac boot/calendar behavior.

## Review Focus

- Empty cases, missing expectations and unsupported schema must fail instead of reporting success.
- Duplicate/empty case identifiers and unknown workday mode must fail.
- Explicit time zone and ISO offsets must be used independently of the host clock/locale.
- Duration/eligibility mismatches must identify the case and return nonzero.
- Either Core and the shared fixture must trigger both platform workflows.

### Task 1: Shared fixture, real core checkers and CI

**Files:**
- Create: `Tests/Shared/attendance.json`, `Tests/AfterSixParityChecks/main.swift`.
- Create: `windows/HappyLulu.ParityChecks/Program.cs`, `windows/HappyLulu.ParityChecks/HappyLulu.ParityChecks.csproj`.
- Modify: `Package.swift`, `.github/workflows/macos.yml`, `.github/workflows/windows.yml`, `docs/PLATFORM-VALIDATION.md`, `docs/PLATFORM-STATUS.md`.

**Interfaces:** `swift run --build-system native AfterSixParityChecks Tests/Shared/attendance.json`; `dotnet run --project windows/HappyLulu.ParityChecks/HappyLulu.ParityChecks.csproj -c Release -- Tests/Shared/attendance.json`. Both report 17 checked cases or exit nonzero with the failed case/invalid input.

- [x] Create explicit 17-case fixture from the recorded ordinary/last Friday, half-day, lower-bound and time-window examples.
- [x] Implement independent check executables against actual cores, preserving all existing checks. No production behavior is added; these are tests of the existing contract.
- [x] Run actual checkers with a temporary incorrect duration and eligibility; observe nonzero case-specific failures, then run the unchanged authoritative fixture and observe 17/17 passes.
- [x] Reject empty/duplicate/missing/malformed/schema/mode inputs in both real executables.
- [x] Wire platform CI and cross-Core/shared-fixture paths; update the runnable validation contract while preserving the single feature table.
- [ ] Run existing Swift core/calendar suites, Windows 63 checks and the new checks; obtain an independent read-only review of the stable patch.
- [ ] Commit/push a bounded PR, wait for both Mac and Windows CI, integrate, update issue #27/Page and verify main bytes/branch cleanup. Never close unrelated incomplete issues.

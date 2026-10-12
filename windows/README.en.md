# HappyLulu for Windows 1.2.1 candidate

The publicly available version is **1.2.1**, available from [GitHub Releases](https://github.com/young221718/happylulu-app/releases/tag/windows-v1.2.1). It rounds hours up to one decimal place and retains light cards, extra elapsed time, and meal time thresholds after scheduled departure. It does not verify work or approve payment.

HappyLulu runs in the Windows notification area. Left-click its icon for today's arrival, estimated departure, manual entry, and day-off action. Right-click to open the separate Settings window or exit. In Settings, choose System, Korean, or English; the preference is saved locally and the open windows and tray text refresh.

While the app is running, the first actual Windows `SessionUnlock` event in the allowed arrival window is recorded. Full days use 08:00–10:00; a morning off uses 13:00–15:00. An afternoon off can be selected with manual entry. The app does not reconstruct earlier unlocks or treat startup, wake, or a session change alone as an arrival. Day off clears today's arrival and suppresses later unlocks until a manual entry resumes recording.

Records stay in `%LOCALAPPDATA%\HappyLulu\state.json`. If the file cannot be read, the app preserves it and disables saving. Settings includes work and break duration, recent arrivals, and an optional Start with Windows switch. The switch changes the current user's Run registry entry only when selected. If you move the portable executable, set startup again.

Calendar sync and in-app automatic updates are not included in the Windows 1.2.1 candidate.

Windows and Mac use the same `main` development base. See [Mac and Windows feature status (Korean)](../docs/PLATFORM-STATUS.md) for differences and development status.

## Build and check

Run with the .NET 10 SDK on Windows:

```powershell
dotnet run --project windows/HappyLulu.Checks/HappyLulu.Checks.csproj -c Release
dotnet publish windows/HappyLulu.Tray/HappyLulu.Tray.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:PublishTrimmed=false -p:DebugType=None -p:DebugSymbols=false -o dist/windows/self-contained
dotnet publish windows/HappyLulu.Tray/HappyLulu.Tray.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -p:PublishTrimmed=false -p:DebugType=None -p:DebugSymbols=false -o dist/windows/runtime-required
```

`HappyLulu-1.2.1-windows-x64.zip` includes the runtime. The smaller `HappyLulu-1.2.1-windows-x64-runtime-required.zip` requires the **.NET 10 Desktop Runtime x64** on the target PC. Extract either ZIP and run `HappyLulu.exe`. CI builds both ZIPs and checks that the runtime-required ZIP stays below 25 MiB.

Core checks and a successful build do not prove real session unlock detection, tray display, startup after sign-in, or execution with an installed runtime. Verify these on Windows separately.

[Windows release notes (Korean)](RELEASE-NOTES.md)

In Settings, **Remaining time display** offers milliseconds, seconds, minutes, hours, and hours/minutes (default). The preference applies to Today and the tray tooltip and persists across restarts. Hours round up in 0.1-hour (six-minute) steps: 90 minutes shows 1.5 h and 30 minutes shows 0.5 h. Whole hours omit the decimal; any positive remainder shows at least 0.1 h, and zero or expired time shows 0 h. Other units keep their existing rounding; milliseconds refresh every 0.1 seconds while the countdown is active. Attendance calculations and overtime guidance remain unchanged.

License: [noncommercial use and full source disclosure for code reuse](../LICENSE). See [third-party notices](../THIRD_PARTY_NOTICES.md) and [release delivery](../DEPLOYMENT.md).

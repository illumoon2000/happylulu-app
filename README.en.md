<div align="center">
  <img src="Resources/HappyLuluIcon.png" width="104" alt="HappyLulu smiling clock logo">
  <h1>HappyLulu</h1>
  <p><strong>Less to keep track of. More room to focus.</strong></p>
  <p>The time you keep checking and the calendar details you need, together.<br>A Mac menu bar and Windows tray companion that makes room for your work.</p>
  <p><sub>Tokens by <strong>lululab</strong> &nbsp;·&nbsp; Chat by <strong>Chan-Young Choi</strong></sub></p>
  <p>
    <a href="https://github.com/young221718/happylulu-app/actions/workflows/macos.yml?query=branch%3Amain"><img src="https://github.com/young221718/happylulu-app/actions/workflows/macos.yml/badge.svg?branch=main" alt="macOS CI · main"></a>
    <a href="https://github.com/young221718/happylulu-app/actions/workflows/windows.yml?query=branch%3Amain"><img src="https://github.com/young221718/happylulu-app/actions/workflows/windows.yml/badge.svg?branch=main" alt="Windows CI · main"></a>
    <a href="https://github.com/young221718/happylulu-app/actions/workflows/site.yml?query=branch%3Amain"><img src="https://github.com/young221718/happylulu-app/actions/workflows/site.yml/badge.svg?branch=main" alt="Site CI · main"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-Custom%20NC-7057d9" alt="Custom noncommercial license"></a>
  </p>
  <p><a href="#downloads">Downloads</a> · <a href="docs/USER-GUIDE.en.md">User guide</a> · <a href="https://happylulu.cy-choi-lulu.chatgpt.site/en/">Web demo</a> · <a href="README.md">한국어</a></p>
</div>

<p align="center">
  <img src="docs/assets/preview-en.jpg" width="1200" alt="HappyLulu web product demo example: today's time and product introduction">
</p>

<p align="center"><em>An illustrative web product demo, not a capture of the actual app. See the public-version and candidate details below.</em></p>

<a id="available-downloads"></a>

## Downloads

| Platform | Direct download | Requirements · details |
| --- | --- | --- |
| **Mac 1.5.12 · build28** | [Download DMG](https://github.com/young221718/happylulu-app/releases/download/macos-v1.5.12-build28/HappyLulu-1.5.12-universal.dmg) · [ZIP](https://github.com/young221718/happylulu-app/releases/download/macos-v1.5.12-build28/HappyLulu-1.5.12-universal.zip) | macOS 13+ · Universal · [Release and checksums](https://github.com/young221718/happylulu-app/releases/tag/macos-v1.5.12-build28) |
| **Windows 1.5.12** | [Download ZIP](https://github.com/young221718/happylulu-app/releases/download/windows-v1.5.12/HappyLulu-1.5.12-windows-x64-runtime-required.zip) | Windows 10/11 x64 · .NET 10 Desktop Runtime x64 required · [Installation guide](windows/README.en.md) |

**Mac 1.5.12 · build28 / Windows 1.5.12** detect automatic arrivals from 06:00 and record observations before 08:00 at 08:00. Manual entry and morning-half-day rules stay unchanged. Actual user sessions, this version’s installation and permission preservation need separate validation. Windows has no calendar sync or built-in updater.

<a id="three-small-steps"></a>

## Quick start

1. **Give it a home.** On Mac, open the DMG and move the app to `Applications` or `~/Applications`. On Windows, install .NET 10 Desktop Runtime x64, then extract the entire ZIP to a permanent folder. Quit the old app before replacing it in the same location.
2. **Click the smiling clock.** Open the menu bar or tray panel. Enter your arrival and workday mode if you have already arrived.
3. **Make it yours.** Choose work and break hours, language and countdown format in settings.

[Detailed installation and usage](docs/USER-GUIDE.en.md#three-small-steps) · [Windows guide](windows/README.en.md)

<a id="a-small-app-for-a-lighter-day"></a>

## Keep what matters within reach

- **Time at a glance.** See arrival, expected departure and remaining time in the menu bar or tray. Choose five display formats and Korean or English.
- **Your workday, your settings.** Set work and break hours, morning or afternoon half days, and the last-Friday reduction.
- **Less record keeping.** While running, the app records the first valid screen unlock and preserves manual edits and day-off choices.
- **Calendars together.** Browse arrival history and events from the selected calendars by month in Mac settings, with date details and sync status. Half-day recognition, connections and sync settings remain available. [Supported scope (Korean)](CALENDAR.md)
- **Personal records stay local.** Attendance works without an account. Mac and Windows attendance records do not sync with each other.

HappyLulu is a personal convenience tool, not the company's official attendance, payroll or meal-payment system.

<a id="today-in-the-menu-bar-settings-in-one-place"></a>
<a id="how-a-day-is-calculated"></a>
<a id="calendars-when-you-need-them"></a>
<a id="records-and-updates"></a>
<a id="releases-and-website"></a>

## Documentation

| Guide | What you will find |
| --- | --- |
| [User guide](docs/USER-GUIDE.en.md) | Installation, settings, workday calculations, records and known limits |
| [Windows guide](windows/README.en.md) | Runtime requirements, tray, startup and builds |
| [Mac and Windows feature status (Korean)](docs/PLATFORM-STATUS.md) | Not planned, in development, completed, and the shared main workflow |
| [Calendar guide (Korean)](CALENDAR.md) | Mac support, connections, previews and recovery |
| [Mac release notes](RELEASE-NOTES.md) · [Windows release notes](windows/RELEASE-NOTES.md) | Version features and public status |
| [Updates](UPDATES.md) · [Deployment](DEPLOYMENT.md) · [Validation](VALIDATION.md) | Signing, release preparation and remaining device checks (Korean) |
| [Website source](site/README.md) | Product introduction and web demo |

<a id="development-and-evidence"></a>

## Contributing

Start with an [issue](https://github.com/young221718/happylulu-app/issues). Changes follow issue → task branch → checks and independent review → PR. Read the [build and validation guide](docs/USER-GUIDE.en.md#development-and-evidence), and keep personal records, keys, credentials and generated apps out of Git.

Use the shared **`main`** as the development base and PR target. New shared features should have matching implementations and validation on Mac and Windows. Track current differences and remaining work in the [feature status document (Korean)](docs/PLATFORM-STATUS.md).

## License

[HappyLulu Noncommercial Source-Sharing License 1.0](LICENSE): commercial use is prohibited without separate written permission. Modifying or reusing the code requires publishing the complete corresponding source of the resulting work under the same license before first use, including private use and network services. Individuals may run the unmodified official app to track their own working hours, including at work. Personal data and signing keys are never subject to source publication. This is **source-available, not OSI open source**. [Third-party notices](THIRD_PARTY_NOTICES.md) remain under their original licenses.

# HappyLulu user guide

[Overview](../README.en.md) · [Downloads](../README.en.md#downloads) · [한국어](USER-GUIDE.md)

Detailed installation, workday calculations, settings, calendars, records and updates. This guide describes **the public Mac 1.5.14 build30 release**. Public downloads are Mac 1.5.14 build30 and Windows 1.5.13.

[Getting started](#three-small-steps) · [Workday calculations](#how-a-day-is-calculated) · [Calendars](#calendars-when-you-need-them) · [Records and updates](#records-and-updates) · [Development and evidence](#development-and-evidence)

## A small app for a lighter day

- **Today, within reach.** Check your arrival and departure countdown. Enter an arrival manually if you have already started.
- **Your routine.** Set work and break hours, half days, five countdown formats, and Korean or English.
- **Two hours earlier on the last Friday.** Regular workdays get the monthly reduction automatically.
- **Your records, on your computer.** Attendance works without an account. Connect calendars on Mac when you need them.

HappyLulu is a personal convenience tool, not the company's official attendance or payroll system.

## Available downloads

| Edition | Version | Status |
| --- | --- | --- |
| [Public Mac download](https://github.com/young221718/happylulu-app/releases/tag/macos-v1.5.14-build30) | **1.5.14 · build30** | macOS 13+ · Universal DMG/ZIP · manual installation |
| [Public Windows download](https://github.com/young221718/happylulu-app/releases/tag/windows-v1.5.13) | **1.5.13** | Windows 10/11 x64 · .NET 10 Desktop Runtime required |

Except for explicitly labeled candidate features, the guide below describes the **current public version**. Check the [Mac](../RELEASE-NOTES.md) and [Windows](../windows/RELEASE-NOTES.md) notes for features in each public version. Mac and Windows attendance records do not sync with each other.

## Three small steps

1. **Download and give it a home.** On Mac, move the app from the DMG or ZIP to Applications or ~/Applications. On Windows, install the Desktop Runtime and extract the entire ZIP to a permanent folder. Quit the old app before replacing it in the same location.
2. **Click the smiling clock.** Open the menu bar or tray panel. Enter your arrival and workday mode if you have already arrived.
3. **Make it yours.** Choose work and break hours, language and countdown format. Calendar setup is optional.

Mac first launch attempts login-item registration and may require system approval. A disabled preference stays disabled. Windows startup is enabled explicitly in settings. Follow the installation steps above and the [Windows README](../windows/README.en.md).

## Today in the menu bar. Settings in one place.

Mac puts settings in one window with a sidebar, including Calendar.

| View | Controls |
| --- | --- |
| Today | Countdown, arrival, expected departure, workday mode and day off |
| General | Language, countdown format and login startup |
| Work | Work and break hours |
| Attendance | Last seven records and record folder |
| Calendar | Half-day recognition, account setup, preview, sync, conflicts and holds |
| Updates | Version and automatic check/install preferences |

Choose milliseconds, seconds, minutes, hours or hours/minutes. Hours round up to one decimal: **90 minutes → 1.5 hours**, **30 minutes → 0.5 hours**. The menu bar and panel use the same preference, which survives a restart.

## How a day is calculated

The default is eight work hours plus one break hour. Arrival windows include their final minute.

Automatic detection starts at **06:00 local time**. Regular or afternoon-off observations from 06:00 through 07:59:59 are recorded at **08:00 on the same day** (06:30 observed → 08:00 recorded → default departure 17:00). Earlier events are ignored; morning off retains 13:00–15:00. The table below describes manual input and recorded times; manual entries are not normalized.

| Mode | Arrival window | Default example |
| --- | --- | --- |
| Regular | 08:00–10:00 | 09:00 → 18:00 |
| Afternoon off | 08:00–10:00 | 09:00 → 13:00 |
| Morning off | 13:00–15:00 | 13:00 → 17:00 |

Regular days finish two hours earlier on the last calendar Friday of the month. Half days use four hours without a break or an extra Friday reduction. Holidays do not move this rule to another date.

Mac records the first valid **observed** login-item launch or screen unlock. Later unlocks preserve arrival, manual edits and day-off choices. Ordinary manual launch, wake and session activation do not create arrivals. The app does not reconstruct hours when it was closed or detect office location/Wi-Fi; an unlock at home may count.

Day off clears today's arrival after confirmation and suspends automatic recording. Saving a manual arrival resumes it. Extra elapsed minutes appear 30 minutes after scheduled departure; a meal time threshold appears after two hours. These do not verify work or approve payment.

## Mac 1.5.15 candidate

**Mac 1.5.15 build31 candidate (release preparation, unpublished)** adds a compact panel and in-place HH:mm arrival edits saved on Enter or clicking elsewhere. Editing only the time preserves automatic calendar recognition or an existing manual choice. Today’s regular, morning-off, afternoon-off, Lulu and leave choices work without a calendar connection and do not create an arrival by themselves. Invalid times, future times, stale dates and incompatible modes are rejected.

In the candidate, Lulu reduces the day by 120 minutes; explicitly choosing regular work overrides the reduction to zero, including on the last Friday. Leave pauses automatic recording and the countdown while retaining the arrival. The separate Day off action can still delete that retained record after confirmation. Windows remains at 1.5.13 without these new panel, Lulu, leave or explicit zero-reduction behaviors.

## Calendars, when you need them

On Mac, open **Settings → Calendar**. macOS Internet Accounts manages account login and credentials. Two-way sync requires **full calendar access**.

1. Connect your own Google and DaouOffice accounts in macOS.
2. Select test calendars from different accounts.
3. Review planned changes, holds and conflicts before starting.

Mac preserves ordinary display reminders. Recurring events are copied as individual occurrences within **30 days before through 365 days after today**. Invitations become personal copies without re-inviting attendees, and the original stays protected. Automatic deletion, out-of-range occurrences and special alarms remain held with a reason.

Resume a paused connection after a fresh preview. A successful local macOS calendar save is separate from confirmation on both web servers. [Calendar setup, supported fields and recovery (Korean)](../CALENDAR.md).

Optional half-day recognition reads accessible calendar titles. Shared events may be mistaken for yours; choose a manual mode or disable recognition. Manual selection takes priority.

## Records and updates

The Mac 1.5.15 build31 candidate has no published signed package, Release or feed yet. Actual app replacement, relaunch and permission/record/connection preservation remain untested. Publication awaits either real installation testing or an explicitly approved no-installation publication path.

Mac attendance stays in `~/Library/Application Support/AfterSix/state.json`. The app identifier and existing storage path are retained. Never delete records to update the app. Calendar connection state is local; macOS manages credentials. No attendance telemetry, keyboard or screen collection is added.

Automatic checking, downloading, idle installation and fixed self-signing are available. The previous 1.5.11 build27 local replacement preserved records, connections and calendar permission, and its public files and signed feed matched the validated package. Actual user-app replacement and permission preservation have not been tested for 1.5.14 build30. This does not verify automatic migration from the old Site feed or installation on every Mac. Older versions with updates disabled need one manual replacement with an enabled version. See [updates](../UPDATES.md) and [issue #3](https://github.com/young221718/happylulu-app/issues/3).

Apple Developer ID/notarization and Windows publisher signing are incomplete. Universal builds include Intel code, but Intel physical testing is pending. Follow managed-device policy. Older versions may preserve but stop writing records containing an unsupported login source; do not remove the records to downgrade.

## Development and evidence

Use Swift 6 and macOS Command Line Tools. Windows has its own [.NET build guide](../windows/README.en.md).

```sh
swift run --build-system native AfterSixChecks
swift run --build-system native CalendarSyncChecks
swift run --build-system native CalendarSyncServiceChecks
bash scripts/build-app.sh
```

Mac PR CI checks core logic, isolated integration, ad-hoc app packaging and Sparkle configuration without private signing keys. See [UPDATES.md](../UPDATES.md) for local fixed signing, signed installation tests and Universal release checks.

Automated checks, app builds, actual device behavior and web-server readback are separate evidence. Track [validation](../VALIDATION.md), [Mac device checks #4](https://github.com/young221718/happylulu-app/issues/4) and [login startup #13](https://github.com/young221718/happylulu-app/issues/13).

Changes follow **issue → task branch → checks and independent review → PR → merge → signing/deployment → readback**. Keep personal records, keys, credentials and generated apps out of Git.

## Releases and website

GitHub owns source, CI, release assets, checksums and the signed update feed. The [website](https://happylulu.cy-choi-lulu.chatgpt.site/) focuses on the product, an interactive demo and download links. See [DEPLOYMENT.md](../DEPLOYMENT.md) for preparation, verification, draft releases, promotion and readback. Website source lives in [site/](../site/README.md). Private signing keys stay in the maintainer’s local keychain; CI does not publish an unverified signed update. The GitHub feed migration requires a one-time installation for existing apps using the old Site feed.

## License

[HappyLulu Noncommercial Source-Sharing License 1.0](../LICENSE): commercial use is prohibited without separate written permission. Modifying or reusing the code requires publishing the complete corresponding source of the resulting work under the same license before first use, including private use and network services. Individuals may run the unmodified official app to track their own working hours, including at work. Personal data and signing keys are never subject to source publication. This is **source-available, not OSI open source**. [Third-party notices](../THIRD_PARTY_NOTICES.md) remain under their original licenses.

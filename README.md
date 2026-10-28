# menubar-usage

A macOS menu bar app for CPU, memory, Grok Bot, and Cursor model usage. It has no Dock icon and no main window. Click the status item to open the panel, and quit from that panel.

Requires macOS 13 or later. The status item is a SwiftUI `MenuBarExtra` with the `.window` style, and the app is an agent (`LSUIElement`).

## Build and run

Open `MenuBarUsage.xcodeproj` and run the MenuBarUsage scheme, or from the repo root:

```bash
xcodebuild -project MenuBarUsage.xcodeproj -scheme MenuBarUsage -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/MenuBarUsage.app
```

Tests:

```bash
xcodebuild -project MenuBarUsage.xcodeproj -scheme MenuBarUsage -destination 'platform=macOS' -derivedDataPath build/DerivedData test
```

The Debug build is ad-hoc signed so it can run on the machine that built it. For a copy you hand to someone else, sign it with your Apple Development team in Xcode (Signing & Capabilities).

The built app is an agent, so it shows in the menu bar and not the Dock. Quit with the Quit button in the panel.

A non-interactive check prints CPU, memory, the auth source, and usage rows, then exits. It does not print the session token:

```bash
build/DerivedData/Build/Products/Debug/MenuBarUsage.app/Contents/MacOS/MenuBarUsage --dump
```

The status item is one template image laid out by AppKit: a monochrome `cpu` symbol, the CPU percent, a middle dot, a monochrome `memorychip` symbol, and the memory percent. Inspect that image before installing:

```bash
build/DerivedData/Build/Products/Debug/MenuBarUsage.app/Contents/MacOS/MenuBarUsage --dump-status-image /tmp/status.png
```

That writes a 4× preview of the `36%` / `68%` label. It does not spell CPU or Mem, and it does not include the chart-bars icon. Network, battery, and AI usage stay in the panel.

## What the panel shows

- CPU percent, from Mach host CPU ticks, refreshed about every 3 seconds. The card keeps an “All cores” line.
- Memory used and total. Used memory is active + wired + compressed pages; the total is `ProcessInfo.physicalMemory`.
- Network down and up rates for the primary interface, with a short sparkline of recent samples. Refreshed on the same cadence as CPU.
- Battery percent, whether it is charging, on AC power, or on battery, and time remaining when the system reports it. Desktops with no battery omit this row. A short sparkline shows recent charge level.
- An **AI usage** section, refreshed about every 90 seconds.

Legacy Cursor plans (Pro, Pro+, and the other monthly plans) keep separate meters:

- **Grok Bot**, with its reset.
- **Cursor models** — `autoPercentUsed`, reset at `billingCycleEnd`.
- **Other models** — `apiPercentUsed`, when that pool is separate. The row is the percent, bar, and reset.

The X Subscription shares one weekly Cursor-model pool across Cursor and Grok Bot. On that plan the panel shows a single **Included AI usage** row, plus **Other models** only when that pool is actually separate. The same percentage is not drawn twice. A weekly plan whose monthly pools are both sitting at 0 while the week is partly spent does not show a fake 0% Other models row.

`totalPercentUsed` is the included figure only when the two pools are not reported. `plan.used` / `plan.limit` is a different denominator and is not shown next to the pool percentages.

## Authentication

No token is committed, logged, or copied into the repo.

1. A session token you paste is stored in the login Keychain under `com.jxzheng.menubar-usage.session` and is used first. Forget removes it.
2. Otherwise the app reads `cursorAuth/accessToken` from Cursor's local `state.vscdb` and builds a `WorkosCursorSessionToken` cookie from the JWT `sub` and the token. That token is not written to the Keychain.

Databases, first match that has a usable token:

- `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
- `~/Library/Application Support/Cursor - Insiders/User/globalStorage/state.vscdb`
- `~/Library/Application Support/Cursor Nightly/User/globalStorage/state.vscdb`

The database is opened read-only. The only row read is `cursorAuth/accessToken`.

If Cursor is signed out, the session is expired, or the saved token is an encrypted `cursor-safe-storage:` value, the panel asks you to open Cursor or [the usage dashboard](https://cursor.com/dashboard/usage). This build does not decrypt Cursor's safe-storage blob and does not read the browser cookie database. Usage rows stay empty until a real session responds.

The app is not sandboxed, because a sandboxed app cannot read Cursor's Application Support database.

## Usage requests

These are the dashboard calls the Cursor site already makes. They are undocumented and can change.

- `GET https://cursor.com/api/usage-summary` with the `WorkosCursorSessionToken` cookie. `billingCycleEnd` is the reset. Pool percentages are `autoPercentUsed`, `apiPercentUsed`, and `totalPercentUsed`.
- `POST https://cursor.com/api/dashboard/get-plan-info` to see whether included usage is weekly.
- `POST https://cursor.com/api/dashboard/get-current-period-usage` for the weekly included percent when the plan says the pool is weekly.
- `POST https://cursor.com/api/dashboard/get-sand-usage-status` for Grok Bot's own allowance. The row is omitted when the account has no included Bot allowance.

Redirects are not followed, so the session cookie is not sent on to another host.

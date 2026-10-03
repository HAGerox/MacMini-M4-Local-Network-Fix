# Toggle Local Network

A native macOS utility that works around the M4 Mac mini local-network bug by toggling every enabled Local Network permission off and back on after a reboot.

## How it works

The app talks directly to macOS's Accessibility API (`AXUIElement`). It does not use AppleScript, `System Events`, Apple Events, or Automation permission. The only permission it needs is Accessibility.

It opens System Settings at Privacy & Security, selects Local Network by its semantic Accessibility identifier, reads every permission row, and presses each enabled switch off and back on. It confirms each change, then rereads the full list throughout an adaptive settling window, including permissions that started off. Normal verification stays on the same page without scrolling, navigating away, or reopening System Settings. A failed attempt still uses a fresh session for recovery. This checks the displayed switch states; a permanently stale display can conceal a saved-state mismatch. The live tests independently reopen Settings after each scenario to check the saved states.

## Installation

1. [Download the latest alpha](https://github.com/HAGerox/MacMini-M4-Local-Network-Fix/releases/tag/v2.1.0-alpha.1), open the DMG, and drag `Toggle Local Network.app` into Applications.
2. Open it. The alpha is not notarised, so the first time macOS refuses: go to System Settings > Privacy & Security and click **Open Anyway**.
3. macOS asks for Accessibility access. Switch on **Toggle Local Network** in Privacy & Security > Accessibility. The app notices and carries on by itself.

To run it after every restart, add it in System Settings > General > Login Items. If the Mac is locked when it starts, it waits until it is unlocked.

Do not use System Settings while the app is running.

## Reliability and safety

- **App identity checks.** Permissions are tracked by name, not position, and every press is refused unless the row still shows the expected app. Apps sharing a name are tracked by order and the run stops rather than guessing if their number changes.
- **Linked rows.** System Settings links rows of apps with the same name (for example several `CapCom` entries), so pressing one flips them all. These are pressed once per group and switched straight back on.
- **Adaptive waits.** The app measures how quickly System Settings shows each change. Each enabled app is switched off, allowed to settle, and switched back on before the next app is touched. Settling and response waits use those measurements, which carry over to retries. A press with no effect ends the attempt instead of being repeated in the same session; fixed upper limits prevent indefinite waits.
- **Retries.** A failed attempt is retried up to three times, each with a freshly launched System Settings. A frozen System Settings is force-quit.
- **Recovery after interruption.** Before the first press, every permission about to change is saved to `~/Library/Application Support/Toggle Local Network/pending-restore.json`. If a run fails, a final pass in a fresh System Settings switches them back on. If the app is killed or the Mac loses power mid-run, the next run repairs them.
- **Watchdog recovery.** A watchdog force-quits System Settings after 90 s without progress and relaunches the app after 150 s; the relaunched copy repairs anything left off.
- **Screen lock.** If the Mac locks during a run, the app waits for the unlock and continues.
- **One copy at a time.** A second copy (for example a login item and a manual launch) exits immediately.
- **Clear failure reporting.** If a run cannot finish, an alert names every app that may have been left off, with buttons to try again, open the settings or show the log.
- **Logs.** Every run is logged to `~/Library/Logs/Toggle Local Network`, with an Accessibility snapshot of System Settings after any failed attempt.

Runtime depends on System Settings' response speed. On the development Mac, a live reset of 48 enabled permissions took about 23 seconds, including verification on the current page.

## Build from source

This project requires macOS 15 or later and Swift 6.

```bash
scripts/build_app.sh          # Release/Toggle Local Network.app and .zip
scripts/build_dmg.sh          # also Release/Toggle Local Network <version>.dmg
```

The app is a universal binary (Apple silicon and Intel). Its bundle identifier is `com.hagerox.ToggleLocalNetwork`. Supply a stable certificate so Accessibility approval survives rebuilds:

```bash
CODE_SIGN_IDENTITY="Apple Development: your certificate name" scripts/build_dmg.sh
```

Without one, the scripts sign ad hoc and macOS may require the rebuilt app to be re-enabled in Accessibility settings.

## Tests

Unit, chaos and build tests use a simulated System Settings and never touch the real one:

```bash
tests/run_tests.sh
CHAOS_SEEDS=20000 tests/run_tests.sh   # longer randomised soak
```

The live suite runs inside the app bundle against the real System Settings. It temporarily changes Local Network switches and checks that every switch ends where it started:

```bash
CODE_SIGN_IDENTITY="Apple Development: your certificate name" RUN_UI_TESTS=1 tests/run_tests.sh integration
```

It covers a normal reset, scroll position, System Settings open on another pane or already on Local Network, a frozen System Settings, System Settings killed mid-reset, the app crashing mid-reset, the app hanging mid-reset, a press aimed at the wrong row, System Settings in German, focus stolen during a reset, two copies at once, and repeated back-to-back resets. The app must have Accessibility permission, and the Mac must stay unlocked.

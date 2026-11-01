---
summary: "Grouped provider critters, combined daily cost, and the fork release drill."
read_when:
  - Syncing or installing the grouped provider icons fork
---

# Grouped provider icons

Base: upstream `v0.83.0` (`348e2fa8d`). Branch: `fork/grouped-provider-icons`.
The branch stays separate from fork `main` until the operator authorizes a merge.
Push only to `origin` (`sm0keyyy/CodexBar`). Do not open an upstream PR without authorization.

Enable **Merge icons**, then **Show every provider**, in Settings > Menu Bar.
The new setting defaults to off. Grouping needs at least two enabled first-party providers.
It shows the first six in menu order, independent of the Overview subset.
Plugins do not supply tiles. A click opens the unchanged merged menu and provider switcher.
Grouping overrides the stored icon style, stacked rows, layout, and icon source without changing their values.

Each critter uses the split-mode renderer inputs. The compositor trims horizontal alpha bounds only.
The gap is three device pixels at 2×. At 1×, slices widen outward to whole pixels and the gap is two device pixels.
Provider colors remain intact. Stateless quota warnings tint only the affected tile.
Generic session and weekly windows supply warnings; provider-specific extra-window maps remain outside this feature.
Template composites retain AppKit dimming. Colored and high-contrast composites use pre-tinted, non-template pixels.

## Daily cost and budget

Cost tracking must be enabled. The sum includes all enabled first-party providers, not only the six visible tiles.
Fleet sources are excluded. Codex and Claude use the existing local Cost today estimates and USD conversion.
Loading and unpriced providers remain named in the tooltip. No loaded amount means no cost title.
Grok is always labelled as an estimate. Unknown Grok models cost zero and appear in the tooltip.
The budget is USD; zero or an empty field disables it. Only a strictly greater USD total turns the title amber.
Display conversion uses the existing preferred-currency formatter.

Grok follows CodeBurn's per-request log method, not context tokens multiplied by a price:

- `src/providers/grok.ts` at `3c186491` defines unified-log requests, deduplication, and session fallback.
- `src/models.ts` at `354492e5` defines standard-speed cost and the exact `grok-4.6` 200k prompt tier.
- `src/data/litellm-snapshot.json` at `9d9ac21d` supplies the single price table in `GrokPriceTable.swift`.
- `GrokPriceTable.verifiedOn` records the price review date, `2026-11-01`.

The log lives under `$GROK_HOME`, or the existing Grok home helper's default.
A session directory counts only if no valid inference request in the retained log identifies it.
Session totals count on the local day of the summary's update date, matching CodeBurn.
The `grok-4.6-build` suffix uses base prices and does not receive the high tier.
Reasoning is already part of output and is never charged twice.

The observable cache scans off the main actor. Usage refreshes schedule it; it has no timer.
It permits one task at a time, at most once per 60 seconds, with an immediate new-day scan.
The signature uses log size and modification time, plus summaries modified since local midnight.
Unchanged signatures skip parsing. Read failures retain the previous value and log once without file contents.
Tests suppress the singleton's real-home scans.

## Upstream hooks

Paths below are relative to `Sources/CodexBar`.

| Hook | File :: function :: diff shape | Guard |
| --- | --- | --- |
| H1 | `Settings/SettingsStoreState.swift` :: `SettingsDefaultsState` :: append two defaulted fields | Settings defaults and persistence |
| H2 | `Settings/SettingsStore.swift` :: `loadDefaultsState` :: append two initializer arguments | Settings defaults and persistence |
| H3 | `Settings/SettingsStore+MenuObservation.swift` :: `menuObservationToken` :: read both keys after stacked bottom selection | S3 and settings observation |
| H4 | `StatusItem/StatusItemController+Animation.swift` :: `applyIcon(phase:bypassMergedMenuTrackingDeferral:)` :: grouped early return after the tracking guard, before `defer` | S1 |
| H5 | `StatusItem/StatusItemController+Animation.swift` :: `blinkAmount`, `wiggleAmount`, `tiltAmount`, `loadingBlinkAmount`, `setButtonContent`, `loadingPercentEpsilon` :: remove `private` | S5 |
| H6 | `StatusItem/StatusItemController+IconObservation.swift` :: `storeIconObservationSignature` :: grouped early return; `providerStoreIconObservationSignature` :: remove `private` | S2 |
| H7 | `Settings/PreferencesMenuBarPane.swift` :: `MenuBarPane.body` :: insert `GroupedProviderIconSettingsRows` after merged style picker | Settings UI |

The controller extension mirrors the split branch of `applyIcon(for:phase:statusItem:merged:)`.
Diff that branch on every upstream sync. Keep provider style, loading morphs, Claude's cylon substitution,
motion, stale state, status indicator, hidden critters, and quota layout policy aligned.
S5 compares rendered tile pixels against split status-item images.
The grouped observation signature includes every tile, warning level, cost state, Grok result, local day, and budget.
S2 protects non-primary providers from stale renders.
H5 also exposes the existing `loadingPercentEpsilon` constant. The build detail omitted its private access level.
Sharing that constant keeps loading pixels aligned without copying a second value.
The operator approved two build-detail deviations on 2026-11-01: H5 exposes that constant, and the Italian catalog gate
unions `SettingsStoreGroupedIconTests.localizationKeys` into its unchanged-English allowlist.
The second hook changes one assertion in `Tests/CodexBarTests/LocalizationLanguageCatalogTests.swift`.
It keeps all 12 grouped strings in English in every locale, as the spec requires, without weakening other catalog checks.

## Tests and gates

Run the six suites: `GroupedProviderIconComposerTests`, `GroupedProviderIconPlanTests`,
`GroupedDailyCostTests`, `GrokCodeBurnCostTests`, `GroupedProviderIconStatusItemTests`, and `SettingsStoreGroupedIconTests`.
The settings suite checks all 23 locale catalogs for the same 12 grouped keys.

```sh
make test-fast FILTER=Grouped
make test-fast FILTER=Grok
make test-fast FILTER=ProviderArchitectureGatekeeper
make test-fast FILTER=Localization
make check
make test
```

`test-fast` wraps `swift test --filter` with the repository's isolated, credential-scrubbed test environment.
Do not run live account probes or permit Keychain access for these gates.
A failed S1, S2, S3, or S5 guard means the corresponding upstream hook or mirror needs attention.
After the operator's next Grok session, compare today's tooltip with CodeBurn built at or after `3c186491`.
That live comparison is separate from fixture tests.

## Release and install drill

1. Fetch upstream tags. Rebase the feature branch onto the new upstream release tag.
2. Reapply hooks by function name, not old line numbers. Diff the split renderer mirror.
3. Diff CodeBurn's Grok parser and pricing code against the commits above.
   Re-copy current Grok snapshot rows into `GrokPriceTable` and update `verifiedOn`.
4. Run every gate above. Package with `CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh release`.
5. Quit CodexBar. Before the first fork install, copy `/Applications/CodexBar.app` with `ditto`
   to the new `~/Applications/CodexBar-0.83.0.app` rollback path.
6. Run `brew uninstall --cask codexbar`. Never use `--zap`; it removes cost history and other state.
7. Copy the packaged `CodexBar.app` with `ditto` to the now-absent `/Applications/CodexBar.app`. Relaunch it.
8. Approve Keychain prompts yourself. Never use `--clear-adhoc-keychain`.
   Restore the CLI symlink only if needed and the packaged CLI helper exists.

Ad-hoc releases keep the bundle ID and local history. They disable Sparkle updates and cannot use upstream iCloud entitlements.
Homebrew no longer owns the installation. Each upstream release needs a fork rebuild and reinstall.
Every ad-hoc rebuild can trigger new Keychain prompts.
If a write guard blocks installation, stop and provide `~/Developer/scratch/codexbar-install.sh` for the operator.
Do not bypass the guard.

For later reinstalls, quit and move the previous fork app aside before copying the new bundle.
Never overlay app bundles: stray files can break the signature.
For rollback, move the fork app to `~/Applications/CodexBar-fork.app`, then `ditto` the preserved 0.83.0 app
back to `/Applications/CodexBar.app`, and launch it.

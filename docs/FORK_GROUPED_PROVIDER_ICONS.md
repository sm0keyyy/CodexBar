---
summary: "Grouped provider pills, the Pace panel and sampler, daily cost, and the fork release drill."
read_when:
  - Syncing or installing the grouped provider icons fork
---

# Grouped provider icons

Base: upstream `v0.83.0` (`348e2fa8d`). Pace branch: `fork/pace`, after `fork/next` at `679229263`.
The Pace branch stays separate from `fork/next` and `main` until the operator authorizes a merge.
Push only to `origin` (`sm0keyyy/CodexBar`). Do not open an upstream PR without authorization.

Enable **Merge icons**, then **Show every provider**, in Settings > Menu Bar.
The new setting defaults to off. Grouping needs at least two enabled first-party providers.
It shows the first six in menu order, independent of the Overview subset.
Plugins do not supply tiles. In Pace mode, a click opens the Pace panel instead of the merged menu.
Grouping overrides the stored icon style, stacked rows, layout, and icon source without changing their values.

Every visible provider uses the same 24 × 10-point rounded pill on a 24 × 18-point canvas.
The gap is three device pixels at 2× and two pixels at 1×.
One measured window fills the whole pill. Multiple windows split it: shortest above, longest below, separated by one pixel at 2×.
The tooltip retains both exact percentages even when cost tracking is disabled.
The weekly fill keeps the exact provider brand color, including Claude.
The session fill derives from that color: lighter and less saturated when feasible, otherwise darker and less saturated.
Tests require absolute CIELAB lightness separation of at least 20 and CIEDE2000 distance of at least 15 for every palette color.
They check Aqua and Dark Aqua appearances and require both fill-to-track CIEDE2000 distances to be at least 15.
Stale, refreshing, highlighted, inactive-display, and quota-warning states never replace or fade either fill.
Stale and refresh-with-data states use a dashed outline. No data uses a solid outline without a fill or tick.
Warnings color the outline amber or red and flash its stroke, not the usage pixels.
Every pill remains non-template and its interior pixels remain opaque, including on inactive displays.
The 111-provider palette run checks both appearances (222 measurements).
Its minimum absolute ΔL* is 20.9828, minimum fill ΔE2000 is 23.0995, and minimum fill-to-track ΔE2000 is 21.0304.
For Codex, Claude, and Grok, the respective (ΔL*, ΔE2000) pairs are (32.4429, 27.8406), (34.4929, 31.1060), and (34.5000, 31.3325).
Both appearances produce the same opaque-fill measurements.
ElevenLabs, Windsurf, Codebuff, Hugging Face, and Vercel use the approved darker-session alternative because their brand fills are too light.
Equal-duration alternatives retain the authoritative primary/secondary windows instead of replacing the weekly value with an appended model-specific quota.
The weekly-62% regression measures 28 solid filled pixels across a 46-pixel inner width, within one device pixel of 62%.
Empty tracks maximize their minimum CIEDE2000 distance from both fills over five neutral candidates.
The grey-state defect came from the grouped controller selecting a template mask for stale/highlight/contrast states.
That mask used one fill for both halves; the compositor also multiplied stale alpha by 0.45.
State regression tests check both appearances, final composition, full alpha, and Claude's rendered orange hue/saturation.
The real-status-bar proof also retained orange at 95% session / 62% weekly in ready, stale, refreshing,
highlighted, and inactive/contrast states. The pre-Pace cold-loading proof showed a colored dashed outline without invented usage.
It ran in a temporary accessory app hosting the isolated test bundle; unbundled SwiftPM helpers cannot reliably register a status item.
The synthetic status items were removed after capture.

## Pace panel

`PaceMode.isActive(settings:store:)` is the shared predicate for the panel, pill, and sampler.
It needs Merge icons, Show every provider, and at least 2 enabled first-party providers.
Outside Pace mode, the existing native menus and history gates stay unchanged.
The panel replaces hosted submenus in grouped mode. Plugin tabs, fleet stacks, Codex workspace rows, and OpenAI web items remain outside its scope.
The panel shows the selected provider account. Settings controls account selection.

### Host and glass

The 360 pt panel uses a borderless, non-activating `NSPanel` at `.popUpMenu` level.
It can become key, but never becomes the main window.
The panel starts 4 pt below the status item and stays at least 8 pt inside the horizontal and bottom screen edges.
Tall content scrolls. A click with either mouse button toggles the panel and retains the item's highlight while open.
Open calls `store.noteMenuOpened()`. Pace mode never builds the merged `NSMenu`.

The panel closes on:

- Esc or a second click on the status item.
- A click outside the panel or loss of key status.
- A Space change, screen change, or sleep.
- An action that opens a window or URL.

Refresh leaves the panel open. Configured `ProviderSwitcherShortcuts` select tabs or move between tabs.
Command-R refreshes, Command-comma opens Settings, and Command-Q quits.
Native focus traversal serves Tab, Shift-Tab, Return, and Space.
The last selected tab uses the existing merged-switcher settings.
The Overview chart starts on Weekly when the panel opens.

`PaceGlassView` uses `.popover`, `.behindWindow`, and `.active`.
Its tint is black at 0.40 alpha in dark appearance and white at 0.50 alpha in light appearance.
It has a 12 pt corner radius, a 0.5 pt white border at 0.14 alpha, and a system shadow.
Reduce Transparency uses an opaque window-background tint. The open panel observes `NSApp.effectiveAppearance`.
The panel uses AppKit APIs, not FineTune source code.

While open, store observation rebuilds content and a 60 s timer updates countdowns.
Close removes event monitors, observers, and the timer, and releases the panel and `NSHostingView`.
The host remains attached to the status button without resident panel content.
Verbose `menuLogger` events are `[perf] pace-panel open latency_ms=<n>` and `[perf] pace-panel close`.
If key focus fails, the host logs `pace-panel key focus unavailable` once. Mouse paths remain available.
The operator must check real key focus and VoiceOver. Injected host tests do not prove those paths on the installed app.

### Overview and provider tabs

The Overview has tabs in grouped-provider order and these sections:

- A shared Session/Weekly chart with remaining percent against the fraction of the window elapsed.
- Timeline bars with reset countdowns, ideal ticks, and pace text.
- Today's total and each provider's amount, from the same `GroupedDailyCost` inputs as the tooltip.
- A 7-day cost chart with daily stacks per provider.
- Refresh, Settings, About, and Quit actions.

Provider tabs share one template, including Grok:

- The header shows the provider's plan, account, update time, and pace summary.
- Plan Usage keeps separate burndowns for multiple windows, or one burndown and a stat row for a single window.
- History chips select recorded windows. The history chart shows used percent through per-period peaks.
- Cost shows Today, 7 days, 30 days, a 30-day chart, and the current weekly-window cost where available.
- The model table shows the top 3 priced models, then `all other models`. Unknown prices stay `unpriced`, never a false zero.
- Credit rows, provider cost rows, and filtered `MenuDescriptor` actions retain the existing provider data.

The panel omits Status Page, Changelog, Share Usage Snapshot, Buy Credits, and agent sessions.
It also omits account actions for a provider with at most 1 account and no error.
Errors restore recovery actions, including login and Copy Error.
Charts use SwiftUI paths, not Swift Charts. Burndowns connect captured samples only, without an invented start point.
The panel takes fill and track colors from `GroupedProviderIconComposer`.
Timeline rows and charts expose spoken summaries, and tabs expose selection.
New strings use `pace_` localization keys in all 23 catalogs.
The operator chose real translations instead of the build plan's English-copy default.

### Pill, pace, and tooltip

The fill follows `usageBarsShowUsed`. Each measured lane gets a 1 pt ideal tick in the button's `labelColor`.
The ideal is `100 * fractionElapsed` in used mode and `100 * (1 - fractionElapsed)` in remaining mode.
Reserve is remaining percent minus ideal remaining percent.
Text rounds half away from zero, as `ahead +17%` or `behind −9%`. Rounded zero reads `ahead +0%`.
Durations up to 1,440 minutes use the session class. Longer durations use the weekly class and weekly warning thresholds.
A Grok window with a `Weekly` label and no duration uses 10,080 minutes.
A missing reset, unresolved duration, synthetic placeholder, or time outside the window gives no tick or pace text.

|State|Fill and tick|Outline|
|---|---|---|
|Normal|Usage fill and ideal tick|0.5 pt solid|
|Refresh with data or stale|Full-opacity fill and tick|0.5 pt dashed|
|Quota warning|Full-opacity fill and tick|1 pt amber or red, with the existing warning flash|
|No data|No usage fill or tick|0.5 pt solid|
|Over budget|Same fill and tick, orange cost text|Unchanged|
|High contrast|Text only, no tick|None|

The tick center is `0.5 + 23 * tickPercent / 100` pt.
At 1×, the compositor floors the column and clamps it to 1...22.
At 2×, it rounds the center and draws 2 columns, clamped to 1...46.
One one-shot timer targets the next device-pixel move, with 10% tolerance. No tick means no tick timer.
The render signature includes tick columns and the fill mode. The pill has no animation or per-minute timer.
The compositor removes the outer image inset before the first pill. The cost slot keeps fixed width and position.
During reload, the slot retains the last complete total of the same local day at 0.55 alpha.
The panel reads that same `GroupedTooltipOwner.costSlot`, not a second retention cache.

Tooltip lines name only the windows that the pill draws, with percent, pace, and reset countdown.
The Today line has exact total and provider amounts. Budget, unpriced, and overflow lines remain.
The AppKit tooltip-owner hover path remains unverified on a real status item.
The approved fallback assigns `button.toolTip` on render and mouse entry, then every 60 s only while hovered.
Mouse exit removes that hover timer. This timer does not redraw the pill.

### Unified usage sampler

While Pace mode is active, successful refreshes record measured windows without the history opt-in or provider history allowlist.
Outside Pace mode, the original capability and opt-in rules still apply.
The sampler skips synthetic or nonfinite values, unknown extra windows, and windows without positive durations.
It excludes samples that already exist with the same series name and canonical duration.

|Window|Series|Duration|
|---|---|---|
|Existing Codex and Claude windows|Existing names|Existing duration rules|
|Grok primary, Weekly label|`weekly`|Resolved duration, or the 10,080-minute fallback|
|Grok primary, Monthly label|`monthly`|Measured duration|
|Grok primary, no recognized label|`credits`|Measured duration|
|Other measured primary and secondary windows|Session or weekly class, with existing provider-specific names|Measured duration|
|Known extra window|`extra:<id>`|Measured duration|

Durations stay raw outside the existing ±10-minute canonical snap.
Limit-reset detection sees only its original samples.
The history path creates Pace samples after the detector call and appends them after generic session-equivalent reconciliation.
This order preserves Grok history across cadence changes and keeps extra series out of reset detection.
Only Pace mode selects `updatedPaceSamplerHistories`.
The updater retains the latest reset-segment peak per hour bucket and coalesces existing split-hour entries.
The bounds remain 1 entry per series per UTC hour bucket and at most 17,520 entries per series.
The sampler keeps the current per-provider JSON format under `~/Library/Application Support/com.steipete.codexbar/history/`.
Account ownership and identity checks remain intact. The sampler does not reconstruct Grok history from before the build.

History persistence runs only when an hour completes, a reset or cadence changes, reconciliation replaces a series, or the app quits.
Refreshes still update the live canonical sample, including its capture time, without scheduling a disk write.
An hourly save excludes the current hour. The live history itself holds that hour's one pending sample per window.
Quit uses `applicationShouldTerminate` to await the utility persistence lane before AppKit exits.
The coordinator retains its existing single pending snapshot only while a write is in flight; there is no timer or new sample buffer.
The 17,520-entry cap and reset-segment peak selection stay unchanged.
Provider JSON documents use atomic whole-document replacement, not append: appending bytes would make this format invalid.
The existing byte comparison skips unchanged providers. Ownership migrations still use the existing immediate save paths.

The deterministic I/O fixture uses 288 five-minute refreshes over 24 hours, isolated directories, and no provider or credential access.
The pre-fix `bc7c3cac6` path wrote 288 times for both `grok.json` and `chatbox.json`, even with unchanged quota values.
It wrote 373,536 bytes for unchanged values, 377,136 for changing values, and 377,034 with a mid-hour reset.
An unchanged one-series document grows from 285 to 2,309 bytes; every write replaces the whole document.
These are encoded payload bytes, not filesystem block or process-wide I/O counters.
`PaceSamplerTests` records each successful atomic write and its byte count, verifies off-main-thread writes, and reloads each fixture.

|Fixture file|`fork/next`, unchanged|Pace before, unchanged|Pace after, unchanged / changed / reset|
|---|---|---|---|
|`grok.json`, `chatbox.json` (each)|0 writes, 0 bytes with tracking off|288 writes, 373,536 bytes|24 / 24 / 25 writes; 31,128 / 31,428 / 32,781 bytes|
|`claude.json` (one standard window)|288 writes, 355,968 bytes|Same timestamp-driven writer as `fork/next`|24 / 24 / 25 writes; 29,664 / 29,964 / 31,256 bytes|
|Grok priced daily cache|No persisted file|No persisted file|No persisted file, 0 bytes|
|UserDefaults reset-detector data for a newly sampled short-window provider|0 sets, 0 bytes|288 sets, 67,392 encoded bytes|0 sets, 0 bytes in all three scenarios|

After the fix, unchanged Grok documents write 285 + 88 × (hour - 1) bytes per completed hour, for hours 1 through 24.
Changed Grok documents write 286 + 89 × (hour - 1) bytes; the reset fixture adds one 1,353-byte write.
The Claude fixture writes 61 fewer metadata bytes per document; its reset adds one 1,292-byte write.
The final canonical sample is flushed on quit. The first 12 unchanged refreshes and same-hour restart refresh write zero bytes.
The pre-fix regression produced 78 assertion failures over six cases; the fixed fixture checks exact byte totals and pending-sample bounds.

The tests also compare the unchanged non-Pace path with `fork/next` and check restart behavior.

Pace adds or changes the `history/<provider>.json` documents for measured windows.
Codex and Claude already used those files in `fork/next`; Pace adds windows and bypasses the other providers' tracking gates.
Generic reconciliation modifies those same documents. It does not append to a separate recorder file.
`GrokDailyCostCache.daily`, its native session cache, and token republication are memory-only.
S4 does not add a priced-daily disk cache or change the Pi/OMP fragment cache format or write seam.

The capability bypass also exposed a detector-isolation defect for short-window providers without history support.
The session detector persisted `lastObservedAt` on every refresh, even when quota values did not change.
The synthetic Chatbox fixture emitted 288 UserDefaults sets of 234 bytes each in every scenario; the pre-fix test failed in all three.
The fix restores the original history-capability gate around reset celebrations. Existing provider detectors retain their behavior.
Pace's own canonical/reset-segment updater remains independent and records the post-reset peak with zero detector sets.
These keys belong to the standard `com.steipete.codexbar` preferences domain (`Library/Preferences/com.steipete.codexbar.plist`).
UserDefaults replaces domain content through cfprefsd rather than appending; physical plist size and write coalescing are OS-managed.
The harness counts encoded detector payload bytes, not the physical domain-file bytes. It never opens the user's preferences.



## Daily cost and budget

Cost tracking must be enabled. The sum includes all enabled first-party providers, not only the six visible tiles.
Fleet sources are excluded. Codex and Claude use local Cost today, including Pi/OMP assistant and `model_usage` side calls.
Loading and unpriced providers remain named in the tooltip. No loaded amount means no cost title.
Known per-request Grok token costs use the same unmarked display as Claude/Codex. Only session-rollup or partially unpriced totals retain the estimate marker.
The budget is USD; zero or an empty field disables it. Only a strictly greater USD total turns the title amber.
Display conversion uses the existing preferred-currency formatter.

Grok combines native Grok logs with xAI calls routed through Pi/OMP, including side calls such as cache warming.
The shared mirror scanner assigns Anthropic, OpenAI Codex, and xAI calls to their model maker's tile.
Other backends stay in the standalone Pi ledger. CodeBurn calls these harness rows `omp`, not Claude, Codex, or Grok;
compare its model breakdown rather than its empty native-provider rows.

- CodeBurn 0.9.27's installed source map contains `src/providers/pi.ts` (`createOmpProvider`), `src/providers/grok.ts`,
  and `src/models.ts`. There is no separate upstream `src/providers/omp.ts`.
- Claude and Codex retain finite, positive per-message recorded USD. Zero or absent USD uses the shared tariff.
  This preserves actual one-hour Claude cache writes and OpenAI charges instead of repricing them at another tier.
- OMP `model_usage` records count independently of assistant messages. Entry timestamps select the local day;
  a message's earlier start timestamp must not move a completed call across midnight.
- Grok uses models.dev's xAI catalog with the official tiers at <https://docs.x.ai/developers/models>,
  reviewed on `2026-11-01`. `GroupedCostPriceTable.swift` contains the tier overlay and offline fallback.
  Known Grok long-context families double all buckets at **at least 200,000 prompt tokens**
  when the catalog has no context tier. New catalog model IDs use their published prices without code edits.
  Prompt size includes fresh input, cache reads, and cache creation. Cache creation has no surcharge.
- CodeBurn 0.9.27's fallback calculation applies that tier only to canonical `grok-4.6`.
  Its OMP parser retains nonzero recorded USD, so already-correct recorded Grok calls can still match.
  When CodeBurn recomputes an unrecorded long-context Grok call, the fork intentionally shows more.
  This comparison stays in internal documentation and fixtures, never in product UI.

Native logs live under `$GROK_HOME`, or the existing Grok home helper's default.
A native session directory counts only if no valid inference request in the retained log identifies it.
Native session totals count on the local day of the summary's update date, matching CodeBurn's rotated-log fallback.
That fallback remains an estimate because it lacks individual inference records.
Pi/OMP calls use their own entry timestamps and are added once, not inferred from native context counters.
Reasoning is already part of output and is never charged twice.

The frozen `2026-11-01T21:23:20.053Z` comparison matches CodeBurn's model USD for the local day:
Opus 5.5 $78.94533820, Haiku 5.5 $0.02497649, GPT-6.1 Sol $15.81724480, and Grok 4.7 $7.84965600.
Over seven days, recursive Grok history totals $225.894408; CodeBurn's normal discovery totals $219.019124.
Its `discoverSessionsInDir` stops after project/session/agent files and omits five depth-four sub-subagent files:
125 real Grok calls costing $6.875284. The fork intentionally retains this spend instead of reproducing the omission.
All other compared model USD match at that cutoff. The retained long-context Grok calls already recorded the official rate;
this corpus therefore has no additional long-context price difference. Fixture tests cover the zero-recorded-cost difference.
The fixture corpus preserves directory depth; flattening it would incorrectly hide CodeBurn's discovery omission.

### Price lookup boundary

`PiSessionCostScanner.add` retains positive recorded Claude/Codex USD; `computedCostUSD` handles their zero/missing-price fallback.
Native Claude/Codex scanners also use `CostUsagePricing` and their existing request-pricing evidence.
The shared resolvers normalize aliases, apply explicit route/custom overrides and historical rates, then consult models.dev and bundled rates.
Unknown models without valid recorded USD or a matching tariff stay unpriced; token and request evidence remains in the report.
Grok's native `GrokSessionCost` and mirrored `computedCostUSD` use `CostUsagePricing.GrokResolver`.
The resolver reads xAI prices from the same models.dev catalog and cache as Claude/Codex.
`GroupedCostPriceTable` supplies offline prices and xAI's inclusive ≥200k prompt tier when the catalog omits it.
Exact catalog model IDs precede bundled aliases, so new models and renames need no code change.
The Grok cache refreshes through `ModelsDevPricingPipeline`; catalog price changes invalidate native and mirror totals.
Unknown Grok families return no price and remain named as unpriced in the tooltip, without a zero-dollar estimate.
No grouped Claude, Codex, or Grok amount comes from a live billing API, account balance, or credit delta.
Recorded OMP USD is a client log value, not an invoice.

The observable cache scans off the main actor. Usage refreshes schedule it; it has no timer.
It permits one task at a time, at most once per 60 seconds, with an immediate new-day scan.
The signature includes mirror cost, tokens, and request count, plus native log size and modification time and updated summaries.
Unchanged signatures skip parsing. Read failures retain the previous value and log once without file contents.
Tests suppress the singleton's real-home scans.

`GrokDailyCostCache.daily` holds the priced 30-day series and `dailyRevision` changes when that series changes.
Native sessions and Pi/OMP mirror rows contribute to the same local-day entries.
Today's daily entry uses the same USD value as the pill's Grok total.
Unknown models retain nil cost and their model rows. A mixed day retains its known priced subtotal.
The cache retains parsed native sessions by path, size, and modification date for the process lifetime.
`GrokPricedDaily.applying(_:to:)` projects the priced days into Grok token snapshots before the history-day filter.
A cache change republishes that snapshot in the same main-actor turn, so panel and spend views read the priced series.
Scan failures retain the previous series. A new local day clears it with the cached Today value.

### Memory

Pi/OMP already streams JSONL records, skips unchanged file stamps, and resumes appended files from their committed offsets.
The persistent cache uses immutable source-file shards through the existing fragment cache.
An unchanged artifact stamp reuses the decoded snapshot across provider reads.
A changed source rewrites its shard, not the full session ledger.
The fragment cache bounds retained snapshots by count and encoded byte cost.
The manifest rename remains the atomic commit point. Corrupt artifacts rebuild from the source files.
The v11 artifact keeps compact entry archives separate from v9/v10 cache formats.
Older artifacts trigger a streaming source rebuild instead of a large legacy JSON decode.
Pricing, day windows, recursive discovery, and duplicate-entry rules remain unchanged.
The Grok worker drains its autorelease pool before the existing malloc relief helper returns free pages to the system.
This work stays off the main actor.
Each provider has a serial utility lane; Grok cannot queue ahead of native scans.

`PiSessionMemoryTests` uses synthetic sessions in one directory.
It asserts zero transcript parses, artifact reads, entry decodes, and shard encodes across ten unchanged refreshes.
The manifest stamp remains unchanged when only the scan time advances.
One appended session requires one parse and one encoded shard smaller than 4096 bytes.
This deterministic buffer guard does not claim a process-wide malloc limit.

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
| H8 | `StatusItem/StatusItemController.swift` :: `attachMenus()` :: first-line `if self.attachPacePanelIfActive() { return }`. `attachMenus(fallback:)` :: first-line `self.detachPacePanel()` | `PacePanelHostTests`, merged-menu suppression and restored click |
| H9 | No hook assigned in the Pace build plan. No upstream edit to reapply | None |
| H10 | `StatusItem/StatusItemController+Shutdown.swift` :: `clearShutdownMenuState()` :: call `detachPacePanel()` immediately before `mergedMenu = nil` | Panel cleanup and shutdown |
| H11 | `UsageStore/UsageStore+PlanUtilization.swift` :: `supportsPlanUtilizationHistory(for:)` :: return true before capability checks in Pace mode | `PaceSamplerTests`, capability bypass |
| H11 | Same file :: `planUtilizationHistorySelection(for:readOnly:)` :: accept Pace mode in the capability guard | History selection and lazy load |
| H11 | Same file :: `planUtilizationHistorySelection(for:account:)` :: same capability bypass, retain loaded-history and account-key guards | Account ownership |
| H11 | Same file :: `planUtilizationHistorySelection(for:snapshotOverride:)` :: same capability bypass, retain loaded-history and snapshot-identity guards | Snapshot ownership |
| H11 | Same file :: `recordPlanUtilizationHistorySample(...)` :: accept Pace mode in the capability guard. Create separate Pace samples after `postLimitResetCelebrationsIfNeeded`. Continue if either sample list has data | Detector isolation, T10-T12 |
| H11 | Same file :: `recordPlanUtilizationHistorySample(...)` :: retain the original history capability around `postLimitResetCelebrationsIfNeeded`, independent of the Pace recording bypass | Unsupported short-window reset: canonical history retained, zero detector defaults bytes |
| H11 | Same file :: `recordPlanUtilizationHistorySample(...)` :: append Pace samples after `reconcileGenericSessionEquivalentHistory`. Select `updatedPaceSamplerHistories` only in Pace mode, otherwise keep `updatedPlanUtilizationHistories` | Cadence transitions, hourly retention |
| H11 | Same file :: `shouldRecordPlanUtilizationHistory(for:)` :: Pace mode OR the original capability and always-tracked/opt-in expression | Opt-in bypass only in Pace mode |
| H11 | Same file :: `planUtilizationHourBucket(for:)` :: remove `private` for the sampler updater. Keep the formula unchanged | Shared hourly bucket |
| H11 | Same file :: `recordPlanUtilizationHistorySample(...)` :: schedule Pace persistence only for hourly completion, a reset, or reconciliation. Save completed hours while the live history retains the current sample | `PaceSamplerTests`, 24-hour write and byte counters |
| H16 | `CodexbarApp.swift` :: `applicationShouldTerminate(_:)` :: await `persistPlanUtilizationHistoryForTermination()` with config persistence and HTTP shutdown | Pending sample durability on quit and termination |
| H12 | `Providers/Grok/UsageStore+GrokLocalSessions.swift` :: `grokLocalTokenSnapshot(from:historyDays:cache:)` :: install the weak cache republisher. Apply `GrokPricedDaily.applying(_:to:)` before the day filter and sum projected daily costs | `GrokPricedDailyTests`, `GroupedCostParityTests` |
| H12 | Same file :: `republishGrokPricedTokenSnapshot(cache:)` :: publish the projected snapshot or confirmed-empty result after cache changes | Same-turn daily projection |
| H13 | `Menu/PlanUtilizationHistoryChartMenuView.swift` :: `Model`, `Point`, `makeModel(history:provider:referenceDate:)` :: remove `private`, with no behavior change | `PaceProviderTabModelTests`, history chips |
| H14 | `Tests/CodexBarTests/LocalizationLanguageCatalogTests.swift` :: `italian localization matches English catalog and includes current UI labels` :: add `.union(PacePanelLocalizationTests.intentionallyUnchangedKeys)` to the unchanged-English allowlist | `PacePanelLocalizationTests`, Italian catalog |
| H15 | `Resources/*.lproj/Localizable.strings` :: all 23 catalogs :: add Pace keys and translated values. Pure formats and Opus remain unchanged | `PacePanelLocalizationTests`, key and format parity |

The grouped controller uses its own uniform pill renderer; the upstream single-provider renderer remains unchanged.
On upstream sync, preserve quota selection, stale state, native contrast/highlight handling, and menu interaction.
S5 guards equal outer geometry, split halves, brand color, and quota routing.
The grouped observation signature includes every tile, warning level, cost state, Grok result, local day, and budget.
S2 protects non-primary providers from stale renders.
H5 remains an existing integration hook; grouped pills do not use critter motion or loading morphs.
The operator approved the original H5 access changes and the Italian catalog gate on 2026-11-01.
The catalog gate unions `SettingsStoreGroupedIconTests.localizationKeys` into its unchanged-English allowlist.
That hook changes one assertion in `Tests/CodexBarTests/LocalizationLanguageCatalogTests.swift`.
It keeps grouped strings in English in every locale, as the spec requires, without weakening other catalog checks.

H11 is wider than the original two-line sampler hook. Preserve every H11 row on an upstream sync.
The capability bypass does not remove account ownership, identity, or history-load checks.
The non-Pace path retains its original updater and detector samples.
H14 names a test file outside the source-relative path convention above.

The panel uses these fork-owned seams, not additional upstream hooks:

|Surface|Seams to preserve|
|---|---|
|`StatusItem/StatusItemController+GroupedIcons.swift`|`groupedProviders` and `groupedCostInputs(now:)` have internal access for the panel adapter. Both remain the shared source of tile order and costs|
|`StatusItem/StatusItemController+PacePanel.swift`|`attachPacePanelIfActive()`, `detachPacePanel()`, and `togglePacePanel(_:)` own native-menu suppression, the click target, and restoration of the original event mask|
|Same file|`makePacePanelContent()` and `makePacePanelInput(now:)` adapt store observation, selected-account card data, histories, token snapshots, and the shared retained cost slot|
|Same file|`performPacePanelCommand(_:)` and `performPacePanelAction(_:)` route shortcuts, tab selection, and native actions. Window and URL actions close the panel first|
|`PacePanel/PacePanelHost.swift`|`PacePanelHost.toggle(anchor:)`, `show(itemScreenFrame:visibleFrame:)`, `refreshContent()`, and `close()` own the panel lifetime|
|Same file|`PacePanelEventSources` injects monitors and notification centers. `PacePanelPlacement.frame(itemScreenFrame:visibleFrame:contentSize:)` clamps placement and scroll height|
|Same file|`PacePanelKeyMap.command(for:shortcuts:)` maps shortcuts. `PaceKeyPanel` owns key eligibility, `cancelOperation(_:)`, `resignKey()`, and key dispatch|
|`PacePanel/PaceGlassView.swift`|`init(frame:)`, `viewDidChangeEffectiveAppearance()`, and `refreshAppearance()` own material, dynamic tint, and Reduce Transparency|


## Tests and gates

Run the grouped suites: `GroupedProviderIconComposerTests`, `GroupedProviderIconPlanTests`,
`GroupedDailyCostTests`, `GrokSessionCostTests`, `GrokAutoPricingTests`, `GroupedCostParityTests`,
`GroupedProviderIconStatusItemTests`, and `SettingsStoreGroupedIconTests`.
The settings suite checks all 23 locale catalogs for the same grouped keys.

Pace adds these suites:

|Suite|Gate|
|---|---|
|`WindowPaceTests`|Fractions, reserve, duration classes, text, invalid windows, and next-pixel timing|
|`GroupedTooltipTests`|Window lines, used/remaining mode, and fallback tooltip refresh|
|`PaceSamplerTests`|All-provider captures, raw durations, capability and opt-in bypass, detector isolation, cadence changes, ownership, hourly coalescing, and retention|
|`GrokPricedDailyTests`|Native and mirrored daily pricing, unpriced models, Today equality, and token projection|
|`PacePanelHostTests`|Placement, scroll height, injected dismissal paths, hosting-view release, native-menu suppression, shortcuts, and observation lifetime|
|`PacePanelModelTests`|Shared cost strings, elapsed-fraction samples, missing history, and forbidden product text|
|`PacePanelRenderProofTests`|Overview defaults, retained reload totals, accessibility summaries, chart labels, and opt-in overview/pill proofs|
|`PaceProviderTabModelTests`|Filtered actions, account and error recovery, cost periods, model rows, history chips, and single/multiple burndowns|
|`PaceProviderTabRenderProofTests`|Populated provider proofs and the 360 pt localized cost layout|
|`PacePanelLocalizationTests`|Source/catalog key equality, duplicate keys, format parity, untranslated prose, and forbidden product text|

The existing composer, daily-cost, status-item, Grok, and plan-utilization suites also guard Pace behavior.
Run these focused gates for the grouped item and Pace:

```sh
make test-fast FILTER=WindowPace
make test-fast FILTER=Grouped
make test-fast FILTER=PaceSampler
make test-fast FILTER=PlanUtilization
make test-fast FILTER=Grok
make test-fast FILTER=GroupedCostParity
make test-fast FILTER=PacePanelHost
make test-fast FILTER=PacePanelModel
make test-fast FILTER=PacePanelRenderProof
make test-fast FILTER=PaceProviderTab
make test-fast FILTER=Localization
make test-fast FILTER=ProviderArchitectureGatekeeper
make check
```

Set `CODEXBAR_PACE_PANEL_PROOF_DIR` to an explicit output directory for the opt-in offscreen proofs.
The Overview suite writes `overview-dark.png`, `overview-light.png`, and `pill-states.png`.
The provider suite writes `claude-dark.png`, `claude-light.png`, `grok-dark.png`, `grok-light.png`, and `codex-dark.png`.
It also writes `grok-cost-localization.png` for the longest localized cost caption and amount.
Without that variable, proof methods skip. Other assertions in those suites still run.
Synthetic proofs do not prove real menu-bar hover, key focus, glass over wallpaper, or VoiceOver.
The operator owns those checks and the installed resource measurements.
The Pace integration slice owns the background full suite, `./Scripts/test.sh --direct-workers 8`, and local-signing package.
No documentation slice installs or launches CodexBar.


`test-fast` wraps `swift test --filter` with the repository's isolated, credential-scrubbed test environment.
Do not run live account probes or permit Keychain access for these gates.
All three AppKit-linked test bundles (`CodexBarTests`, `CodexBarPluginTests`, and macOS `CodexBarLinuxTests`) link `CodexBarTestBootstrap`.
Its load-time initializer sets `NSApplication` policy to `prohibited` before test discovery.
Window tests and opt-in native proofs use `accessory`, not `regular`, so showing a test window cannot register a Dock app.
The earlier bootstrap covered only one bundle and tests could override it with `regular`; startup-only assertions did not cover those transitions.
`AppKitBootstrapTests` checks initialization and bitmap rendering. Full-run Dock monitoring is the end-to-end receipt; production targets do not link this support.
The 2026-11-01 full direct-worker run passed all 162 groups without retries.
Dock accessibility was sampled 468 times at a 500 ms target interval over 234 seconds:
zero `xctest` items before, throughout, and after, with no query failures or Dock restart.
`CODEXBAR_GROUPED_COLOR_PROOF_DIR` enables a credential-isolated real-status-item proof with controlled quota fixtures and file-selected states.
A failed S1, S2, S3, or S5 guard means the corresponding upstream hook or mirror needs attention.
`GroupedCostParityTests` uses sanitized recorded Pi/OMP usage and expected output from installed CodeBurn 0.9.27.
Its explicit `CODEXBAR_GROUPED_COST_CORPUS` mode accepts only a supplied sanitized corpus and prints model/day totals.
It never falls back to the user's session directory. Compare live model totals only over the same frozen corpus and cutoff.

## Release and install drill

1. Fetch upstream tags. Rebase the feature branch onto the new upstream release tag.
2. Reapply hooks by function name, not old line numbers. Check the grouped pill integration.
3. Diff CodeBurn's Grok and Pi/OMP parsers against the installed source map.
   Review xAI's official rows in `GroupedCostPriceTable`, update `verifiedOn`, and bump the mirror cost formula version.
4. Run every gate above. Package with `./Scripts/package_app.sh release`.
   Its default `auto` mode uses the unique `CodexBar Local Signing` identity when available, otherwise ad-hoc signing.
   Use `CODEXBAR_SIGNING=local` to require the local identity and fail rather than fall back.
5. Quit CodexBar. Before the first fork install, copy `/Applications/CodexBar.app` with `ditto`
   to the new `~/Applications/CodexBar-0.83.0.app` rollback path.
6. Run `brew uninstall --cask codexbar`. Never use `--zap`; it removes cost history and other state.
7. Copy the packaged `CodexBar.app` with `ditto` to the now-absent `/Applications/CodexBar.app`. Relaunch it.
8. Approve Keychain prompts yourself. Never use `--clear-adhoc-keychain`.
   Restore the CLI symlink only if needed and the packaged CLI helper exists.

Local and ad-hoc releases keep the bundle ID and local settings/history. They disable Sparkle and upstream iCloud entitlements.
Homebrew no longer owns the installation. Each upstream release needs a fork rebuild and reinstall.
Ad-hoc rebuilds change the designated code requirement; a stable local certificate avoids that identity churn.
Local signing reports team metadata `LOCAL` but retains the original `Y5PE65HELJ.com.steipete.codexbar` shared-data namespace.
Existing widget selections, standard defaults, local usage history, and cost caches remain in place.
If a write guard blocks installation, stop and provide `~/Developer/scratch/codexbar-install.sh` for the operator.
Do not bypass the guard.

For later reinstalls, quit and move the previous fork app aside before copying the new bundle.
Never overlay app bundles: stray files can break the signature.
For rollback, move the fork app to `~/Applications/CodexBar-fork.app`, then `ditto` the preserved 0.83.0 app
back to `/Applications/CodexBar.app`, and launch it.

## Local signing and Claude credential access

On this Mac, run `~/Developer/scratch/codexbar-signing-cert.sh` yourself in an interactive Terminal.
It creates a ten-year self-signed `CodexBar Local Signing` certificate with the code-signing extended key usage.
It imports a non-exportable private key into the login keychain and requests code-signing trust only.
Temporary key containers are encrypted with a one-time random wrapping password and removed on exit.
The script does not read or replace Claude credentials. Enter passwords and approve trust prompts yourself.
Keep this certificate and its key: replacing it creates a new identity and requires new credential approval.

The Claude OAuth reader queries the `Claude Code-credentials` service. CodexBar's cached OAuth credentials use
`com.steipete.codexbar.cache`, with account keys `oauth.claude` and `oauth.claude.profile.<profile hash>`.
Neither query sets a Keychain access group. The app entitlements are generated by `Scripts/package_app.sh`
in `.build/entitlements/CodexBar.entitlements`; the CLI has no Keychain access-group entitlement.
The signed application's Keychain ACL, not the app-group entitlement, controls access to these existing credentials.
The Claude-owned suffixed service `Claude Code-credentials-431392b4` is not the queried default service.

After the final local-signed reinstall, authorize the new identity once:

1. Open Keychain Access, select the login keychain and Passwords, and search for `com.steipete.codexbar.cache`.
2. Open its Claude OAuth entry and select Access Control. Keep confirmation protection enabled.
3. Add `/Applications/CodexBar.app` and its `Contents/Helpers/CodexBarCLI` to the trusted applications.
   Press Command-Shift-G in the application chooser to enter the helper's full path.
4. Save and authenticate yourself. Never choose "Allow all applications" and never delete the stored credentials.
5. Relaunch CodexBar and Refresh Claude. If a native credential-access prompt appears, verify its application and service,
   then approve it yourself. A `never` Claude Keychain prompt policy suppresses such recovery prompts;
   use the explicit manual-access preference only when you want the app to request permission.

No Full Disk Access change is needed for OAuth. Safari cookie imports are a separate fallback with their own privacy permission.

### Claude detection versus authentication

`ClaudeCLIResolver` resolves an executable override, cached login-shell PATH, inherited PATH, known installations, then shell command/alias fallbacks.
`BinaryLocator` already recognizes standard Homebrew and native Claude installations; no personal path override is needed.
The login-shell capture uses `$SHELL -l -i -c` with a six-second timeout and stays process-local until relaunch.
`ProviderVersionDetector` deliberately gates background `--version` calls to avoid an opaque CLI triggering a credential prompt.
A missing version can therefore mean a suppressed probe, not a missing executable.
App Auto prefers OAuth before CLI and Web. OAuth does not require Claude Code's own login or binary.
The operator's stale Claude Code login recovered after the operator reauthenticated; no detection code was changed for that state.

### Recurring Claude credential access

Stable signing does not prevent Claude Code from rewriting its credential item or changing its ACL during renewal.
The operator chose **Settings → Providers → Claude → Keychain prompt policy → Always allow prompts**, with Usage source **Auto**.
The release defaults key is `com.steipete.codexbar` / `claudeOAuthKeychainPromptMode`, string value `always`.
Turning off “Avoid Keychain prompts” alone selects `onlyOnUserAction`, not `always`.
The upstream `never` guard stays unchanged. `always` permits the existing identifiable-profile owner-CLI fallback after typed credential absence.
It permits prompts; it does not guarantee silent operation after renewal or relaunch.
The CLI-success throttle cache is process-local, valid for less than fifteen minutes or until reset, and is lost on relaunch.
Malformed, denied, unidentified, or revoked credentials still fail closed. This fork does not rotate Claude Code tokens.
See <https://github.com/steipete/CodexBar/issues/3798#issuecomment-6048256920> for the maintainer's ACL-renewal explanation.

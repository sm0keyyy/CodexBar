---
summary: "Grouped provider pills, combined daily cost, and the fork release drill."
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

Every visible provider uses the same 24 × 10-point rounded pill on a 24 × 18-point canvas.
The gap is three device pixels at 2× and two pixels at 1×.
One measured window fills the whole pill. Multiple windows split it: shortest above, longest below, separated by one pixel at 2×.
The tooltip retains both exact percentages even when cost tracking is disabled.
The weekly fill keeps the exact provider brand color, including Claude.
The session fill derives from that color: lighter and less saturated when feasible, otherwise darker and less saturated.
Tests require absolute CIELAB lightness separation of at least 20 and CIEDE2000 distance of at least 15 for every palette color.
They check Aqua and Dark Aqua appearances and require both fill-to-track CIEDE2000 distances to be at least 15.
Stale, refreshing, highlighted, inactive-display, and quota-warning states never replace or fade either fill.
Stale/loading states use a dashed outline; warnings color that outline amber/red and flash its stroke, not the usage pixels.
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
highlighted, and inactive/contrast states. Cold loading showed the colored dashed outline without invented usage.
It ran in a temporary accessory app hosting the isolated test bundle; unbundled SwiftPM helpers cannot reliably register a status item.
The synthetic status items were removed after capture.

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
- Grok always uses the official xAI tariff at <https://docs.x.ai/developers/models>,
  reviewed on `2026-11-01`. `GroupedCostPriceTable.swift` is its sole rate source.
  Every published Grok long-context family doubles all buckets at **at least 200,000 prompt tokens**,
  including `grok-4.7`, `grok-4.5`, build aliases, and `grok-4.6-build`.
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
Grok's native `GrokSessionCost` and mirrored `computedCostUSD` both call `GroupedCostPriceTable.cost`.
That file strips a route prefix, applies explicit aliases, then exact or longest known family-prefix lookup.
Unknown Grok families return no price, contribute no USD, and remain named in the tooltip.
No grouped Claude, Codex, or Grok amount comes from a live billing API, account balance, or credit delta.
Recorded OMP USD is a client log value, not an invoice.

The observable cache scans off the main actor. Usage refreshes schedule it; it has no timer.
It permits one task at a time, at most once per 60 seconds, with an immediate new-day scan.
The signature includes mirror cost, tokens, and request count, plus native log size and modification time and updated summaries.
Unchanged signatures skip parsing. Read failures retain the previous value and log once without file contents.
Tests suppress the singleton's real-home scans.

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

## Tests and gates

Run the grouped suites: `GroupedProviderIconComposerTests`, `GroupedProviderIconPlanTests`,
`GroupedDailyCostTests`, `GrokSessionCostTests`, `GroupedCostParityTests`,
`GroupedProviderIconStatusItemTests`, and `SettingsStoreGroupedIconTests`.
The settings suite checks all 23 locale catalogs for the same grouped keys.

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

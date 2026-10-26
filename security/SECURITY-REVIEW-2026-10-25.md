# Switchboard security review — October 25, 2026

Subsequent remediation: the camera action type, action executor, and automatic state-script presentation handler have been removed. Legacy saved or synced camera buttons are unsupported and cannot run either script. The automatic-execution path in finding 1 is closed; ordinary synced AppleScript actions still require trusted publishers because they can run when activated. A regression test verifies both legacy camera paths remain inert/rejected. `swift test` passed all 112 tests after removal. Further remediation: finding 3 is now closed by replacing disk spooling with a nonblocking pipe and a 65,536-byte combined stdout/stderr quota enforced during capture. Overflow, timeout, and cancellation terminate the child, escalating to SIGKILL if needed. Eight regression tests cover boundaries, combined streams, infinite output, ignored SIGTERM, cancellation, timeout, and spawn failure; all 120 Swift tests pass. This bounds captured output, not arbitrary files/resources created by scripts. Finding 2 remains open. The assessment and scan evidence below describe the earlier reviewed snapshot.

Reviewed commit `61575a1` plus the current uncommitted changes, including the new folder controls. The [source hash manifest](reports/2026-10-25/source-sha256.json) identifies the reviewed snapshot. All source hashes were checked against the working tree at the end of the review; they matched. No application code, user settings, credentials, or Home Assistant configuration was changed. New files in `security/` contain this assessment and evidence.

**Result: three actionable security concerns, including a high-impact trust boundary in shared shortcut execution. No security clearance is implied by the automated scans.**

## 1. High — synced camera state scripts execute without approval on the receiving Mac

Locations: `Sources/LogiEasySwitchApp/DeckActions.swift:61-64`, `DeckWindow.swift:300-306`, `DeckSync.swift:253-256` and `346-351`.

Remote shortcut configuration retains `camera` buttons and their `stateScript` settings. Both follower and collaborative sync apply incoming shared configuration directly. When the launcher displays that camera button, its presentation callback invokes `/usr/bin/osascript -e <stateScript>`, on every refresh cycle. There is no local approval of the script's content/version. Activating the button is not required.

An authorized shared-group editor, someone who compromises that editor, or an attacker with write access to the relevant MQTT configuration topics can therefore arrange local code execution on receiving Macs with the receiving user's privileges when the shortcut is displayed. Apple's normal permission checks still apply to protected resources and Apple Events; this is not a bypass of TCC, root elevation, or anonymous Internet access. A script need not use Apple Events to perform local operations.

Proof: a test-only follower received a snapshot containing a camera `stateScript` that simply returned `security-review-proof`. Calling the same presentation method used by the launcher evaluated that script and returned the literal. The test did not run a shell, contact Home Assistant, or modify external files.

This trust model is partly documented: `docs/SHORTCUTS.md` explicitly says inline script source is shared and publishers must be trusted. The finding is the absence of a receiving-Mac execution approval boundary: permission to edit shared layout/content currently confers permission to run code, even via an automatic state refresh. This should be an explicit workplace security decision, not assumed from broker TLS or a group UUID. Per-peer write ACLs alone do not prevent an authorized peer from distributing executable settings to its group.

Recommended change: keep executable script content local by default, or quarantine newly received executable content until each receiving Mac approves a digest of that exact script. Reapproval must be required after changes, including conflict resolution and backup import. Apply this to both action and state scripts; prevent refresh callbacks from evaluating unapproved scripts. Until implemented, only enable shared editing among Macs/users trusted to run code on each other.

## 2. Medium — Home Assistant requests permit plaintext bearer credentials

Location: `Sources/LogiEasySwitchApp/DeckActions.swift:97-109`.

`makeRequest` accepts both `http` and `https` base URLs, then unconditionally attaches the long-lived Home Assistant token as an `Authorization: Bearer` header. The new HTTP API client does not enforce the TLS requirement already used for MQTT.

If the platform/environment permits the HTTP request, a network observer can recover the token and exercise its Home Assistant privileges. Exposure requires an HTTP-configured base URL and access to the network path. A configured HTTPS URL is not affected, and redirects are explicitly refused. App Transport Security can block some insecure requests; that platform-dependent behavior should not substitute for an application policy protecting this credential. See [Apple's ATS guidance](https://developer.apple.com/documentation/security/preventing-insecure-network-connections) and [local-network ATS behavior](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

Proof: a request-builder test constructed an HTTP Home Assistant request carrying a dummy bearer credential. No real token was read or sent; actual plaintext transmission in the signed app was not tested. This finding establishes acceptance/construction of an insecure credential-bearing request, rather than claiming every macOS deployment will transmit it.

Recommended change: require HTTPS before attaching the token and provide a clear configuration error for HTTP URLs. If development-only local HTTP support is necessary, make it an explicit narrowly scoped exception rather than silently accepting arbitrary HTTP origins. Keep certificate verification and redirect refusal intact.

## 3. Medium — subprocess output is bounded only after it has been written to disk

Location: `Sources/LogiEasySwitchApp/DeckActions.swift:152-174`.

The process helper sends both stdout and stderr to a temporary file without a byte quota. The 65,536-byte limit applies only when reading that file after the process exits. During the 60-second execution window a noisy script can consume available disk space. Multiple actions may run concurrently; a remotely supplied camera state script adds an automatic trigger. Temporary-directory permissions and cleanup are good, but do not prevent exhaustion before cleanup.

Proof: a harmless child wrote 1 MiB of dummy output and checked its own stdout file size. The helper returned only 65,536 bytes, demonstrating that truncating the returned result did not cap file growth. The helper removed the temporary file normally; no disk-filling workload was run.

Recommended change: continuously drain both streams, enforce a total byte quota while draining, and terminate the action on overflow. Do not simply stop reading pipes, which can deadlock the child. Consider a concurrency cap as well. Define whether the helper should terminate a process group so descendant processes do not outlive the action's resource controls.

## Automated verification

- `swift test`: **107 tests passed** on the current working tree.
- `npm test`: **4 tests passed**.
- Three additional harmless proof tests passed in an isolated `/tmp` source copy, without editing the app's real test suite. Their source and test log are included in the evidence directory.
- Semgrep 1.182.1 with `p/security-audit` and `p/swift`: **0 findings/errors**, 25 applicable rules, 73 files, approximately 100% parsed lines. Only **2 Swift-specific rules across 63 Swift files**; no implication of comprehensive Swift analysis. The Node test directory is omitted by default ignore patterns; tests were executed separately.
- Gitleaks 8.30.1: **0 detected secrets** in the current-source snapshot and **17 scanned Git commits**. Reports use redaction. This does not cover user Keychain items, preferences, unreachable Git history, or remote-only revisions.

[Evidence and source hashes](reports/2026-10-25/). The static/secret scans ran against the unmodified snapshot before adding the isolated proof-test file. That proof source is saved separately and is not part of the source manifest. Rule packs were downloaded; scans ran locally with Semgrep metrics disabled. Public registry rules can change over time.

No live device switching, Home Assistant actions, broker configuration changes, penetration testing, or installed-app binary security certification was performed. Existing broker ACL, legacy same-user socket impersonation, Developer ID signing and notarization requirements from the previous review still apply. The packaging script supports hardened runtime and a supplied signing identity, but defaults to ad-hoc signing; an approved release artifact must be assessed separately.

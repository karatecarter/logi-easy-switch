# Logi Easy Switch security review

Follow-up: see the [remediation status and rescan results](REMEDIATION-2026-10-24.md). This initial report describes the pre-fix source.

Review date: October 24, 2026 (America/New_York). Reviewed source commit: `c0e7f6b42c5f8b89502ad1d528ca8ee635e440eb`.

**Disposition: scanned, with unresolved security findings. This is not a clean security approval or an independent penetration test.** IT should evaluate the findings and deployment controls before approving workplace use.

## Scope and evidence

Reviewed native Swift app, legacy Node CLI, packaging scripts, permission use, credential storage, HID++ parsing, and MQTT command/data handling. No application source was intentionally uploaded to a scanning service. Semgrep downloaded public rule configurations with metrics disabled; scanning ran locally. Gitleaks ran locally with secret redaction. Tools were obtained from PyPI (Semgrep in a temporary virtual environment) and Homebrew (Gitleaks).

Evidence is in [reports/2026-10-24](reports/2026-10-24/). Source SHA-256 hashes identify the scanned files. The installed app was inspected separately; its executable hash is recorded in `environment.txt`. Its correspondence to this source commit was NOT established, so source findings do not certify that installed binary.

| Check | Result | Limits |
| --- | --- | --- |
| Semgrep 1.182.1, `p/security-audit` and `p/swift` | 0 findings; 25 applicable rules on 25 files | Only 2 Swift-specific rules on 16 Swift files; 20 JS rules on 3 files, plus generic/JSON rules. One file skipped by ignore patterns. No deep interprocedural analysis. |
| Gitleaks 8.30.1, Git history | No secrets detected; 12 commits scanned | Local repository history only; not deleted/unreachable history, remote-only branches, Keychain, or preferences. |
| Swift dependency inventory | No external package dependencies | Apple frameworks, OS components, and toolchains were not checked for CVEs. |
| Node dependency inventory | No declared external dependencies in package.json | `npm audit --json` was attempted but returned ENOLOCK because there is no lockfile; do not describe it as a passed audit. |
| `swift build` | Passed | Build success is not a security test. |
| `npm test` | 2 tests passed | Existing framing tests; no adversarial Swift tests or fuzzing. |
| Installed app signature inspection | Ad-hoc signature; no TeamIdentifier; hardened-runtime flag absent | Signature verification result recorded separately. No Developer ID identity or notarization evidence established. |
| Manual source review | Findings below | Code review, not exploitation testing. Severities are reviewer estimates, not CVSS scores. |

## Findings

### SEC-01 — Medium: MQTT permits plaintext credentials and commands

Evidence: `Sources/LogiEasySwitchApp/MQTTConfiguration.swift:7-8` defaults to port 1883 and `useTLS = false`; `MQTTClient.swift:46` selects `.tcp` when TLS is off. `connectPacket()` puts username/password in the MQTT CONNECT payload.

When MQTT is enabled without TLS, an attacker able to observe the connection can read broker credentials and computer/device activity. An attacker able to modify traffic can tamper with commands/state. MQTT is disabled by default, so this exposure is conditional on enabling the feature and leaving TLS off. TLS uses Apple's Network framework with no custom certificate-verification bypass found.

Recommended remediation: require TLS for workplace deployment, use a trusted broker certificate and dedicated least-privilege credentials, and change the app to default to TLS or explicitly gate insecure connections. Broker credentials exposed on an untrusted plaintext connection should be rotated.

### SEC-02 — Medium: MQTT parser can accumulate unbounded input

Evidence: `Sources/LogiEasySwitchApp/MQTTClient.swift:137-156` appends received bytes to `incoming`. `decodeRemainingLength()` returns nil for a four-byte continuation sequence as well as incomplete input; the caller retains that input and continues reading. Valid large advertised packets also lack an application-level cap. The 65,536-byte receive size limits each read, not total buffering.

A malicious/compromised broker, or a network attacker when TLS is disabled, can cause growing memory use and eventual denial of service. A publisher may also trigger oversized delivery if permitted by broker limits. There is no packet assembly deadline.

Recommended remediation: reject malformed lengths immediately, impose small explicit packet/buffer limits suitable for control messages, set a packet assembly timeout, and disconnect/clear state on violation. Add malformed/oversized/fragmented packet tests.

### SEC-03 — Medium: short HID++ responses can crash the app

Evidence: `Sources/LogiEasySwitchApp/HIDPPTransport.swift:63-72` indexes `info[4]` and slices name-response payloads without checking their lengths. `HIDPPSession.request()` accepts matching reports with as few as six bytes, returning a payload that can be shorter than these callers require.

A malformed response from a faulty or malicious Logitech-identifying peripheral can cause a Swift array bounds trap and terminate the app. This requires interaction with a connected peripheral; no remote code execution was demonstrated.

Recommended remediation: validate minimum response length for every HID++ operation before indexing/slicing, reject invalid host counts/channel values, and test truncated reports and inconsistent name lengths.

### SEC-04 — Medium, deployment-dependent: broker permissions are the command authorization boundary

Evidence: `Sources/LogiEasySwitchApp/MQTTCoordinator.swift` subscribes to the fixed shared topic `logi-easy-switch/command/target` and invokes switching for received target strings. There is no message signature, sender verification, freshness check, or retained-command rejection in the app. All deployments use the same topic namespace.

Anyone allowed to publish to that command topic can request switching to an already paired computer. A retained command can be delivered again when clients subscribe. This is not anonymous Internet access by itself: reachability and broker authentication/ACLs determine access. A shared or permissively configured broker can enable unwanted device redirection or repeated disruption; payloads do not create arbitrary new Bluetooth pairings.

Recommended remediation: use a dedicated broker account with explicit topic ACLs, disable anonymous access, restrict publisher access to approved clients, clear retained command messages, and isolate independent installations with separate namespaces. Consider command expiry/IDs and retained-message rejection. Broker configuration was not inspected.

### SEC-05 — Low: legacy CLI trusts a filename-selected socket in /tmp

Evidence: `src/protocol.mjs:50-59` selects the lexicographically last `/tmp/logitech_kiros_agent-*` entry without checking socket type, owner, or peer identity.

A local process able to create a matching filename can impersonate the legacy Options+ endpoint, spoof responses, or interfere with commands. No broker password transmission through this CLI was found. The native Swift app does not use this socket path.

Recommended remediation: validate socket type/ownership and use a trusted discovery mechanism or explicit validated path; remove the legacy CLI from workplace distributions if unused.

## Distribution and permission considerations

The build script uses ad-hoc codesigning (`codesign --sign -`) and does not enable hardened runtime. IT receives no verified publisher identity from an ad-hoc signature. For managed distribution, use an organization-approved signing identity, hardened runtime, and notarization where required by IT policy; publish release hashes tied to reviewed commits. This is a distribution control gap, not evidence that the app contains malware.

The app requests Input Monitoring for direct HID access and registers global hotkeys. Settings records key events locally while assigning a shortcut. No code path forwarding typed text, arbitrary shell execution, or downloading/executing updates was identified in the reviewed app. This is a limited source-review observation, not a guarantee. MQTT credentials are stored in macOS Keychain rather than preferences; credential-save errors are currently ignored and should be surfaced for reliability.

## Reproducing the automated checks

Run from the repository root with the listed scanner versions installed. Outputs below should go to a fresh directory outside the repository to avoid scanning reports themselves.

```sh
mkdir -p /tmp/logi-security-results
SEMGREP_SEND_METRICS=off semgrep scan --config p/security-audit --config p/swift --metrics off --disable-version-check --json --output /tmp/logi-security-results/semgrep.json .
gitleaks git --redact --report-format json --report-path /tmp/logi-security-results/gitleaks.json .
swift package show-dependencies --format json
swift build
npm test
```

Semgrep registry rules may change over time. The saved JSON and text contain the results from this run; rerunning current registry rules is not an identical frozen-rule reproduction. See [Semgrep's language/rule coverage](https://semgrep.dev/docs/supported-languages/) and [metrics documentation](https://semgrep.dev/docs/metrics) for scanner limitations and configuration.

No fixes were applied as part of this assessment. The broker/network, remote Mac, OS/firmware vulnerabilities, malware scanning of a release artifact, runtime fuzzing, and independent organizational approval remain outside this assessment. Suggested next step: remediate SEC-01 through SEC-03, agree broker ACL/distribution requirements with IT, and rescan/test the exact release artifact IT will deploy.

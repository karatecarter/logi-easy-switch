# Security remediation — October 24, 2026

Subsequent validation: [live TLS deployment and certificate-hostname support](TLS-VALIDATION-2026-10-24.md). The snapshots below describe the earlier remediation build.

This follows the [initial assessment](SECURITY-REVIEW-2026-10-24.md). Changes are an uncommitted working-tree snapshot based on `c0e7f6b42c5f8b89502ad1d528ca8ee635e440eb`; the [evidence directory](reports/2026-10-24-remediation/) contains SHA-256 hashes identifying the exact rescanned files. The initial assessment and its evidence are preserved as historical results.

## Status by finding

| Finding | Implemented | Remaining scope |
| --- | --- | --- |
| SEC-01: plaintext MQTT | New settings default to TLS/8883. Both validation and the client prohibit plaintext. Settings explains how to update old configurations. Standard macOS certificate/hostname validation remains enabled. | Configure a trusted TLS listener and update every participating Mac. Credentials previously exposed on an untrusted plaintext network may need rotation. |
| SEC-02: unbounded MQTT input | Separate bounded framing decoder: maximum body 65,536 bytes; read size 16,384 bytes; bounded accumulation; reject oversized, noncanonical, and malformed lengths. Fifteen-second packet assembly and MQTT CONNACK deadlines; disconnect clears decoder/timers. Reject invalid packet headers, unexpected QoS, and malformed topics. Outbound strings/payloads also have limits. | Live broker interoperability and timeout behavior need deployment testing; regression tests exercise framing and policy without a broker. Broker throughput limits and ACLs still matter. |
| SEC-03: short HID++ response crash | Only fixed-size 20-byte long reports enter the queue; validate report length before payload extraction and constrain host count/current channel to the three Easy-Switch channels. Queue bounded to 64 reports. | Physical device testing and peripheral fuzzing were not performed. Invalid unsolicited reports are discarded, so a bad device can time out rather than crash the app. |
| SEC-04: shared command authority | Carry the retain flag through the parser; reject retained, oversized, malformed, hidden, or unknown target commands. Add configurable validated namespaces for commands, state, availability, and discovery. Existing default topic names are preserved. | **Partially mitigated, not closed as a deployment finding.** Authorization remains with broker ACLs. Live commands have no cryptographic publisher identity or expiry; namespace isolation is not authentication. Set ACLs, restrict reachability/publishers, clear retained commands, and configure separate namespaces for independent installations. |
| SEC-05: untrusted CLI socket discovery | Require an actual root/current-user-owned socket, reject symlinks, skip untrusted candidates, and revalidate before each request. Add bounded IPC framing and receive buffering. | Same-user/root impersonation and pathname races are not fully eliminated; the CLI does not verify peer executable identity. The packaged native app excludes the legacy CLI. IT should distribute only that bundle. |

Additional hardening: Keychain saves now update atomically rather than delete before replacement, report failures in Settings, and use device-only accessibility for newly created credentials. Packaging enables hardened runtime, verifies its signature, supports a supplied `LOGI_SIGNING_IDENTITY` with a secure timestamp, and uses the active installed SDK (optional `LOGI_MACOS_SDK` override) instead of a hardcoded unavailable SDK.

## Verification

- `swift test`: 11 regression tests passed, covering TLS defaults/old-setting rejection, namespace migration/validation, malformed and oversized MQTT lengths, buffer bounds, fragmented/coalesced packets, maximum-size fragmented packets, invalid publications, retained/unknown command policy, all truncated HID long reports, and host/channel bounds.
- `npm test`: 4 tests passed, including malformed/oversized IPC frames and discovery/client rejection of unsafe socket paths.
- `Scripts/make-app.sh`: release build succeeded. `codesign --verify --deep --strict` passed; signature inspection confirms `adhoc,runtime`. No Developer ID signing identity was supplied. The bundle is **not notarized**. Its executable hash is saved in `artifact.txt`.
- `zsh -n Scripts/make-app.sh` and `git diff --check`: passed.
- Semgrep 1.182.1, same public rule packs as the initial scan: 0 findings/errors, 25 applicable rules on 27 source files, including only 2 Swift-specific rules across 19 Swift files. The temporary snapshot is outside the repository; Semgrep's default ignore patterns omit the Node `test/` directory; the Swift `Tests/` file was scanned. All tests were executed, and the snapshot manifest includes both suites.
- Gitleaks 8.30.1 current-source directory scan: no secrets detected. The original history scan is preserved in the initial report; new edits have not yet been committed.

Scanners ran locally against a source snapshot, with Semgrep metrics disabled. Scanner rules remain limited and can change in the registry. Successful scans and tests do not establish absence of vulnerabilities. No live broker, Keychain failure injection, physical switching, or notarized release acceptance tests were performed.

## Deployment impact

**Existing plaintext MQTT settings will stop connecting until TLS is configured.** Select the correct hostname, enable TLS, and use the broker's TLS port on each Mac. All participating Macs must use the same namespace. Legacy clients can still execute retained commands; update them all. Local HID switching remains available without MQTT.

The new bundle was built under `dist/`; it was not installed over the running application, uploaded for notarization, committed, or pushed. Before workplace approval, IT must apply [the deployment controls](DEPLOYMENT.md), supply an approved signing identity/notarization process, and validate the exact resulting release on managed hardware. SEC-04 and the distribution controls remain open pending those steps.

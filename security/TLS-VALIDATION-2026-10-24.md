# TLS deployment validation — October 24, 2026

Follow-up to the [security remediation](REMEDIATION-2026-10-24.md).

The user's existing Home Assistant Mosquitto add-on already offered both plaintext MQTT on 1883 and TLS MQTT on 8883. Its public CA certificate matched a DNS name different from the local address used by the app. Connecting to the certificate's public DNS address on port 8883 was refused, while connecting locally and verifying against the certificate's DNS name succeeded.

No Home Assistant configuration, Mosquitto listeners, credentials, ACLs, router rules, or system DNS were changed. No broker restart was performed. Existing non-TLS clients can continue using the original listeners. The Home Assistant add-on [documents simultaneous plaintext and TLS listeners](https://github.com/home-assistant/addons/blob/master/mosquitto/DOCS.md#option-certfile).

## Application changes

- Added an optional certificate hostname setting. Empty preserves normal verification against the broker address. When set, it selects the expected DNS identity for certificate verification using [Apple's TLS server-name API](https://developer.apple.com/documentation/security/sec_protocol_options_set_tls_server_name(_:_:)). It does not bypass chain, expiry, or hostname validation.
- Validates the configured name and migrates older saved settings with an empty default. Existing TLS requirement remains enforced.
- Handles Network.framework waiting errors by reporting failure and allowing the coordinator's normal reconnect behavior, including certificate errors.
- Updates the standalone MQTT smoke tool to support a separate certificate hostname and removes its unsynchronized captured result mutation.

Installed the updated hardened-runtime development bundle on this Mac and configured the local address, TLS port 8883, and the certificate's verified DNS identity. Exact user-specific settings and credentials are deliberately omitted from this repository report. Other Macs were not updated remotely.

## Validation

- Python's normal TLS verification accepted the broker certificate using the expected DNS identity and negotiated TLS 1.3. Verification against the local address failed with a hostname mismatch.
- The native Swift MQTT client authenticated to the broker, subscribed, published, and received a message using the isolated non-retained `logi-easy-switch/smoke` topic. No device-switching commands were published.
- The native negative smoke test using the incorrect certificate identity failed with a certificate error and exit code 1. Credentials were not included in that negative test.
- Mosquitto's log confirmed that the installed app's normal client connected on 8883 and negotiated TLS 1.3 with `TLS_AES_256_GCM_SHA384`.
- `swift test`: 12 tests passed; `npm test`: 4 tests passed. Includes certificate-hostname validation, serialization, and migration coverage.
- Release bundle built successfully; signature verification passed. It remains ad-hoc signed with hardened runtime, not Developer ID signed or notarized.
- Semgrep and Gitleaks current-source rescans reported zero findings/errors. Coverage limitations from the initial assessment still apply.

[Evidence](reports/2026-10-24-tls/) includes test/build logs, scanner reports, installed artifact hash, and source snapshot hashes. Source changes remain uncommitted. Broker authorization and managed signing/notarization requirements in [DEPLOYMENT.md](DEPLOYMENT.md) remain open; enabling TLS does not implement per-publisher authorization.

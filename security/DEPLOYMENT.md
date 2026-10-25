# Workplace deployment

The app requires MQTT over TLS using macOS's normal certificate and hostname validation. It never falls back to plaintext and has no certificate-verification bypass. Use your broker's TLS listener (usually port 8883). Normally the broker address must match the certificate. If the broker is reachable only through a local address, enter the certificate's DNS name in **Certificate hostname (optional)**. The app then connects to the local address while verifying the certificate against that explicit name using Apple's TLS API; certificate chain, expiration, and hostname verification remain enabled. This does not require exposing the MQTT port to the Internet or changing system DNS. Have IT install any required organizational certificate authority through its approved management process. Existing saved `useTLS: false` settings are rejected with a message in Settings; enable TLS and select the TLS port on every participating Mac.

Use a dedicated account for each approved Mac and the same MQTT namespace for the Macs that share devices. Use different namespaces for independent installations. The namespace is routing isolation, not a password or authorization control. Only already remembered, visible target names are accepted; retained commands are ignored. Live commands retain Home Assistant's plain target-name format. Anyone authorized to publish live commands can switch devices to those targets, so broker authorization remains essential.

Have IT configure these broker controls:

- Disable anonymous access and restrict broker reachability to approved hosts.
- Authenticate approved clients and allow commands only from the participating Macs and approved Home Assistant controls.
- For a namespace such as `work-desk`, allow those clients read/write on `work-desk/command/devices` for scoped keyboard/mouse commands, and on `work-desk/command/target` and `work-desk/state/current-target`. Allow write to `work-desk/mac/<client-id>/availability` and `work-desk/mac/<client-id>/name` for each client's own stable ID. Read permissions for status consumers can be narrower.
- If automatic Home Assistant discovery is enabled, allow publishing only the relevant select, sensor, and binary-sensor configuration topics under `homeassistant/<component>/logi_namespace_work-desk/`. For the default namespace, the discovery ID remains `logi_easy_switch`. Disable discovery if IT manages the entities centrally.
- Clear any retained command on the command topic. Require non-retained command publishing; disable old clients that still execute retained commands.
- Restrict broker payload size and publication rate in addition to the app's limits. Rotate credentials if they were previously sent over an untrusted plaintext connection.

Use the access-control mechanism supported by your broker/version; consult the [Mosquitto configuration documentation](https://mosquitto.org/man/mosquitto-conf-5.html). Avoid broad shared-broker write access such as `#`. Deploying an ACL requires broker administrator access and has not been performed by this repository change.

When changing namespaces, change all participating Macs and Home Assistant controls together. Old retained discovery entities are not automatically deleted; remove them through the broker/Home Assistant's approved process. Do not operate independent installations with the same namespace.

The legacy Node CLI validates that its socket path is an actual socket owned by root or the current user and rejects symlinks and foreign-owned sockets. This does not authenticate the peer executable or protect against a malicious process already running as the same user/root, or all pathname replacement races. For workplace deployment, distribute only the native app bundle; the native app does not use the legacy socket protocol.

## Signing and approval

`Scripts/make-app.sh` enables hardened runtime and verifies its output. By default it uses an ad-hoc signature for local development. For a managed release, set `LOGI_SIGNING_IDENTITY` to IT's approved Developer ID Application identity before building. The script adds a secure timestamp when using a named identity. Certificate provisioning and notarization need organizational credentials; they have not been performed automatically.

Follow [Apple's notarization instructions](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) for the final signed bundle, staple the accepted ticket, and validate Gatekeeper behavior on a managed test Mac. Record the release executable hash and reviewed commit. An ad-hoc build or successful static scan alone is not publisher verification or IT approval.

Validate Input Monitoring approval, global shortcuts, login behavior, device switching, and TLS/MQTT interoperability on that exact signed release. The security regression suite does not replace that hardware and deployment acceptance test.

Shortcut shared-group sync also needs read access to `<namespace>/shortcuts/shared/<group-id>/#` and write access to `<namespace>/shortcuts/shared/<group-id>/<own-sync-id>/#` plus the own-sync-id base topic. Large snapshots use retained chunk subtopics and a digest-verified manifest, preserving the 64 KB MQTT packet bound.

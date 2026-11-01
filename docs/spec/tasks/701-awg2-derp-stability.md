# 701 — AWG DERP large transfers and network recovery

| Field | Value |
|---|---|
| Status | Confirmed lifecycle fixes implemented; long-duration and mobile acceptance remain open |
| Related specs | [Android AWG](700-tailscale-awg-android.md), [peer transport](../features/030-TAILSCALE/FUNCTIONS/peer-transport.md), core task 149 |

## Problem

A control connection can remain healthy while an AWG data plane stalls during a
large transfer or after a network change. Test native direct UDP, forced DERP,
and a supported proxy underlay independently. A passing carrier comparison does
not establish filtering or explain a native transport failure.

## Confirmed fixes

- Android can replace its default `Network` without changing the interface name.
  Track network identity as well as interface metadata, suppress duplicate
  callbacks, and notify the existing core monitor when either changes. Preserve
  socket protection and the single VPN service.
- The core dependency's DERP receive lifecycle must acknowledge/discard borrowed
  frames when a bind closes and reopens. The minimal, pinned dependency patch
  and RED/GREEN regression belong to the core contribution.
- Persisted private DNS protection must coexist with generated Tailscale DNS.
  Keep the protected server and suffix rules instead of dropping them as a
  duplicate of the endpoint's generic resolver.

## Reproduction and acceptance

1. Use an isolated Headscale/reference-peer lab with disposable services and a
   pinned compatible profile. Configure TLS normally and trust a local CA only
   inside the test environment. Keep identity state between lifecycle checks.
2. Send a bounded 16 MiB TLS object in both directions and verify checksums.
   Exercise UDP payloads64/512/1200, private DNS and selected public VLESS.
   Record peer path and counters before and after requests. Include multiple
   rekey intervals and short requests after a bulk transfer.
3. Exercise stop/start/reload and default-network replacement. Assert that the
   machine identity and per-node state directory remain stable. `Running`, a
   visible peer, DISCO or a control handshake alone does not prove success.
4. Repeat ordinary Tailscale and AWG3 DERP regressions when the transport seam
   changes. Test profile mismatch, ACL deny, logout and router outage with no
   private DNS or traffic escaping the protected path.
5. Preserve failed attempts separately from later successful runs. Diagnostic
   instrumentation and alternate paths do not replace acceptance of the clean
   final artifact. Do not increase a timeout or change a profile and call that
   a fix without an identified cause and reproducer.
6. Physical mobile handoff, background behavior and long-duration stability are
   independent acceptance gates. Restore only test-owned settings, helpers and
   lab resources; do not restore stale identity databases or disable OS consent.

## Source contribution boundaries

Publish generic reproducer/runner tooling with runtime-supplied host, device and
artifact arguments. Exclude personal device details, service addresses, packet
captures, credentials, deployment receipts and private profile material. The
engineering source is available for teammate testing; full physical/mobile and
cross-platform completion is not claimed by this task.

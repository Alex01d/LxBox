[English](peer-transport.md) · [Русский](peer-transport.ru.md)

# Peer transport — ordinary Tailscale, AWG2 and AWG3

| Field | Value |
|-------|-------|
| Feature | [030-TAILSCALE](../FEATURE.md) |
| Promises | P25–P26 |
| State | Engineering implementation; physical-device acceptance pending |

## Purpose and controls

Reach a Headscale network and use a selected internet proxy inside one VPN app.
Choose ordinary Tailscale, AWG2 or AWG3; import/edit/export a profile containing
its version, optional label and typed transport parameters. An auth key is
optional: the sign-in link supports manual Headscale approval. Both VPN peers
must support the selected mode and use compatible parameters; the standard
Headscale coordination server and DERP need no AWG fork.

The transport can use direct UDP, an explicit UDP-capable proxy, or DERP through
an explicit TCP proxy. A selected outer proxy failing does not permit native
fallback. "Direct" peer status means no DERP; an outer proxy can still carry it.

## Inputs, outputs and invariants

- A profile contains transport parameters, never device identity. Export can
  include a shared obfuscation key. Existing local identity survives profile
  edits/reload; importing on another device issues that device's own identity.
- Unsupported or unknown AWG capability rejects the whole candidate, leaving
  the last-good configuration available. It never silently switches to plain
  WireGuard. Atomic backups require marker 3; ordinary exports remain marker 2.
- Configured mode, applied mode and safe error are separate from peer presence.
  An applied profile/control handshake does not prove a working data plane.
- Ordinary Tailscale and AWG peers can share a control server, but do not
  transparently interoperate. Peer relay and the embedded SSH server with AWG
  remain outside this engineering integration.

## Verification and boundaries

Profile/schema/round-trip, capability, backup and optional-status tests are task
700 witnesses. Physical Wi-Fi/mobile, background/UI restart, consent revoke,
direct/DERP, failure/leak and ordinary-mode regressions require the dedicated
device. A built APK is not device acceptance or a production rollout.

## Revisions

| Task | Change |
|------|--------|
| [700](../../../tasks/700-tailscale-awg-android.md) | Engineering profiles/status/capability and Android build; device gate pending |

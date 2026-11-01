# 700 — Embedded Tailscale AWG on Android

| Field | Value |
|---|---|
| Status | Engineering implementation; device, ABI and platform acceptance remain open |
| Related specs | [Tailscale](../features/030-TAILSCALE/FEATURE.md), [peer transport](../features/030-TAILSCALE/FUNCTIONS/peer-transport.md), [recovery](701-awg2-derp-stability.md), core task 149, launcher task 175 |

## Problem and scope

Use ordinary Tailscale, AWG2 or the AWG3 family (including AWG3.1 parameters)
through the existing Android VPN application. Headscale remains the unmodified
control plane; the peers must share a compatible data-plane profile. Selected
public destinations may use VLESS while protected destinations use Tailscale.
There is no automatic downgrade from AWG to ordinary WireGuard.

This contribution publishes reusable source, contract vectors, engineering build
tools and specifications. Personal device records, deployment settings, private
profiles, credentials, local artifact paths and raw test captures are excluded.
Source synchronization retains incoming mixins, memory management and release
pins. Portable contract locks store a repository-relative clone hint instead of
a workstation path. Restore resolves that lock-origin hint against the LxBox
repository root, independent of the caller directory; explicit environment
overrides and legacy absolute hints keep their existing meaning. Synchronizing
sources does not install applications or change a running VPN.

## Contract and implementation

1. Sync the authoritative launcher contract through `app/tool/sync_contract.sh`.
   Preserve atomic `endpoints[].awg` (`version`, optional `profile_id`, typed
   `parameters`) and `underlay_mode` (`auto` or `derp`) through import, storage,
   generation and export. Use the shared schema instead of a second protocol
   definition. AWG3.1 is represented by the family-3 profile parameters.
2. Apply generic `fail_build` capability gates before destructive node/field
   filtering. Missing or unknown `with_tailscale_awg` rejects the entire apply
   with `tailscale_awg_core_unsupported`, preserving the profile and last-good
   config. Ordinary Tailscale retains its existing compatibility behavior.
3. Extend the existing Tailscale editor with ordinary/AWG2/AWG3 mode, JSON
   profile import, edit and export. Keep auth key optional and interactive
   login available. Editing and reload retain the stable local node and its
   state directory; exports never transfer machine identity.
4. Extend the existing libbox CommandClient bridge with optional configured and
   applied transport modes and a safe error. Peer availability is separate from
   applied-mode status. Keep one `BoxVpnService`, socket protection, network
   monitor and existing per-node identity storage.
5. Explicit protected CIDR/private-DNS rules reference one endpoint and remain
   present before login, after logout and during outages. Reject a missing
   protected target. Apply these guards after raw mixins, before validation,
   so a mixin cannot remove the promised fail-closed protection. Preserve all
   other mixin behavior and report mixin failures as fatal build issues.
6. Build separate engineering AAR/APK artifacts using an explicit local AAR
   override. Keep published AAR/release pins unchanged until a matching immutable
   core artifact is published and accepted. Maintain the signing channel for
   in-place updates; application data must not be cleared to make a test pass.

## Acceptance

- Focused tests: typed profile/schema preservation, missing/unknown/present core
  capability, marker-3 backup rejection by older readers, static CIDR/DNS guards,
  mixin coexistence, optional transport status and network-identity changes.
- Whole-project `flutter analyze` and named task-related tests; full suites run
  in CI. Run the relevant UI/template checker after editing their inputs.
- Engineering artifact checks: AAR API and build tags, ABI/minSdk, compatible
  APK signature/version, production pin retention and file checksums.
- Isolated peers: AWG2/AWG3 direct and forced DERP, real bidirectional TCP/UDP,
  private TLS/DNS plus public VLESS, invalid profile, ACL deny, logout and outage
  without protected traffic or DNS falling through to direct/VLESS/public DNS.
- Physical device: interactive enrollment, start/stop/reload, stable identity,
  UI/background lifecycle, Wi-Fi changes, mobile handoff and consent revocation.
  A control handshake or `Running` status alone is not data-plane acceptance.
- Other Android ABIs/AAB and desktop Windows/macOS checks remain separate gates;
  a successful engineering build does not close the cross-platform feature.

## Related implementation

The source changes span the existing Tailscale editor/status bridge, Android
network identity tracking, generic config gates, protected-route/DNS builder,
atomic backup support, shared contract assets and opt-in engineering tools.
The production core selection remains governed by `app/android/libbox.version`.
No binary, private topology or device-specific acceptance report is part of this
source contribution. See [engineering builds](../../ANDROID_AWG_ENGINEERING.md)
for reproducible commands and [task 701](701-awg2-derp-stability.md) for the
remaining transport recovery and long-transfer validation boundaries.

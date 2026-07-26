// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

/// The complete schema of keys stored in `NETunnelProviderProtocol
/// .providerConfiguration`. This file is the single source of truth — it is
/// compiled into both the app and the network extension, so the writer
/// (app) and reader (extension) sides can never drift. Do not spell these
/// as string literals anywhere else.
///
/// Ownership notes:
/// - Regular tunnels: `NETunnelProviderProtocol+Extension` preserves unknown
///   keys across edits and owns only `wgQuickConfig` (removed; legacy) and
///   `uid` (restamped, macOS).
/// - Group tunnels (failover, TiT): the providerConfiguration is rebuilt by
///   the `TunnelGroupSpec` implementations in `TunnelsManager+GroupCRUD`.
enum ProviderConfigurationKeys {
    /// Legacy inline wg-quick config, superseded by the keychain reference
    /// (`passwordReference`). Read for migration/import only; never written.
    static let wgQuickConfig = "WgQuickConfig"

    /// macOS: the UID of the user who owns this tunnel configuration.
    static let uid = "UID"

    /// Warm spare cellular failover settings (JSON-encoded
    /// `WarmSpareSettings`). Single-config tunnels only.
    static let warmSpareSettings = "WarmSpareSettings"

    // MARK: Failover groups

    /// Stable identity of a failover group manager.
    static let failoverGroupId = "FailoverGroupId"

    /// Keychain references to the member wg-quick configs, index 0 = primary.
    static let failoverConfigRefs = "FailoverConfigRefs"

    /// Legacy plaintext member configs, superseded by `failoverConfigRefs`.
    /// Read for migration/fallback only; never written.
    static let failoverConfigs = "FailoverConfigs"

    /// Display names parallel to `failoverConfigs`.
    static let failoverConfigNames = "FailoverConfigNames"

    /// JSON-encoded `FailoverSettings`.
    static let failoverSettings = "FailoverSettings"

    // MARK: Tunnel-in-Tunnel groups

    /// Stable identity of a TiT group manager.
    static let titGroupId = "TiTGroupId"

    /// Keychain reference to the OUTER (Server A) wg-quick config.
    static let titOuterConfigRef = "TiTOuterConfigRef"

    /// Keychain reference to the INNER (Server B) wg-quick config.
    static let titInnerConfigRef = "TiTInnerConfigRef"

    /// Legacy plaintext OUTER config, superseded by `titOuterConfigRef`.
    /// Read for migration/fallback only; never written.
    static let titOuterConfig = "TiTOuterConfig"

    /// Legacy plaintext INNER config, superseded by `titInnerConfigRef`.
    /// Read for migration/fallback only; never written.
    static let titInnerConfig = "TiTInnerConfig"

    /// Display name of the tunnel the OUTER config came from.
    static let titOuterName = "TiTOuterName"

    /// Display name of the tunnel the INNER config came from.
    static let titInnerName = "TiTInnerName"
}

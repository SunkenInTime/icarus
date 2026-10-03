// Vendored from vrfkit v0.2.5 (c4d6cc0), crates/vrfkit/src/sink/measured_routes.rs. Apache-2.0;
// see native/replay/NOTICE.md. Local edits: listed in src/vendor/mod.rs.

//! Which checksum-gated structured-array routes a replay branch admits.
//!
//! A [`MeasuredArrayRoute`] expands one exact (group, parent, checksum) identity
//! into additive child rows and types children through handle-keyed member
//! tables, so where a build moved a member the route refuses (counted) or
//! leaves children untyped: the gate is per build AND per route. A route is
//! admitted only where it was observed on that build's replays with every array
//! counter at zero and an independent decoder matched every child; unobserved
//! is not verified and stays off. Measurements: docs/LEGACY_BUILD_SUPPORT.md.

/// One measured structured-array route.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum MeasuredArrayRoute {
    /// `OwnerExclusivePlayerInfo.AllPlayersObfuscatedPlayerInformation`.
    AllPlayersObfuscatedPlayerInformation,
    /// `OwnerExclusivePlayerInfo.TrackedRewards`.
    TrackedRewards,
    /// `PersonalizationComponent.SelectedV2`.
    SelectedV2,
    /// `PlayerMatchStatsComponent.KillData`.
    KillData,
    /// `EffectManagerComponent.ServerActiveEffects`.
    ServerActiveEffects,
    /// `FiniteSpeedMovementComponent.RequestedIgnoreActors`.
    RequestedIgnoreActors,
    /// `BlindManagerComponent.ActiveBlinds`.
    ActiveBlinds,
    /// `MulticastSetPath.NetworkedProjectilePath` (an RPC parameter array).
    NetworkedProjectilePath,
}

impl MeasuredArrayRoute {
    /// Every route, in declaration order.
    pub(super) const ALL: [Self; 8] = [
        Self::AllPlayersObfuscatedPlayerInformation,
        Self::TrackedRewards,
        Self::SelectedV2,
        Self::KillData,
        Self::ServerActiveEffects,
        Self::RequestedIgnoreActors,
        Self::ActiveBlinds,
        Self::NetworkedProjectilePath,
    ];

    const fn bit(self) -> u8 {
        1 << (self as u8)
    }
}

/// The set of routes admitted for one replay branch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(super) struct MeasuredArrayRoutes(u8);

impl MeasuredArrayRoutes {
    /// No route: every parent stays one raw row, and no child is emitted.
    pub(super) const NONE: Self = Self(0);

    /// Every route.
    pub(super) const ALL: Self = Self::of(&MeasuredArrayRoute::ALL);

    const fn of(routes: &[MeasuredArrayRoute]) -> Self {
        let mut bits = 0;
        let mut i = 0;
        while i < routes.len() {
            bits |= routes[i].bit();
            i += 1;
        }
        Self(bits)
    }

    /// The routes admitted for `branch` (the header's branch string); an unknown
    /// branch admits nothing. Pinned by `routes_are_pinned_for_every_supported_branch`.
    /// Legacy entries: all 48 11.06-12.09 replays (three per build) and the
    /// single public 12.10/12.11/13.00 fixtures, main stream and checkpoints.
    /// Held back:
    ///
    /// - `AllPlayersObfuscatedPlayerInformation`, `TrackedRewards` < 12.04: handles +3.
    /// - `SelectedV2` 11.06-11.08: a zero-width `DynamicMappings` at 13 moves the nested array.
    /// - `ActiveBlinds`, every legacy build: `SourceID`/`EffectID` swapped through 12.04,
    ///   9-bit hardcoded-name `SourceID`s from 12.05; refusals move `array_leaf_decode_errors`.
    /// - Any route with no child observed on a build (the path on 11.06, 12.06, 12.07).
    pub(super) fn for_branch(branch: &str) -> Self {
        use MeasuredArrayRoute::{
            AllPlayersObfuscatedPlayerInformation as PlayerInfo, KillData,
            NetworkedProjectilePath as ProjectilePath, RequestedIgnoreActors, SelectedV2,
            ServerActiveEffects, TrackedRewards,
        };
        match branch {
            "++Ares-Core+release-11.06" => {
                Self::of(&[KillData, ServerActiveEffects, RequestedIgnoreActors])
            }
            "++Ares-Core+release-11.07" | "++Ares-Core+release-11.08" => Self::of(&[
                KillData,
                ServerActiveEffects,
                RequestedIgnoreActors,
                ProjectilePath,
            ]),
            "++Ares-Core+release-11.09"
            | "++Ares-Core+release-11.10"
            | "++Ares-Core+release-11.11"
            | "++Ares-Core+release-12.00"
            | "++Ares-Core+release-12.01"
            | "++Ares-Core+release-12.02"
            | "++Ares-Core+release-12.03" => Self::of(&[
                SelectedV2,
                KillData,
                ServerActiveEffects,
                RequestedIgnoreActors,
                ProjectilePath,
            ]),
            "++Ares-Core+release-12.04"
            | "++Ares-Core+release-12.05"
            | "++Ares-Core+release-12.08"
            | "++Ares-Core+release-12.09" => Self::of(&[
                PlayerInfo,
                TrackedRewards,
                SelectedV2,
                KillData,
                ServerActiveEffects,
                RequestedIgnoreActors,
                ProjectilePath,
            ]),
            "++Ares-Core+release-12.06" | "++Ares-Core+release-12.07" => Self::of(&[
                PlayerInfo,
                TrackedRewards,
                SelectedV2,
                KillData,
                ServerActiveEffects,
                RequestedIgnoreActors,
            ]),
            "++Ares-Core+release-12.10"
            | "++Ares-Core+release-12.11"
            | "++Ares-Core+release-13.00" => {
                Self::of(&[PlayerInfo, TrackedRewards, SelectedV2, ServerActiveEffects])
            }
            // The builds every route was first measured on.
            "++Ares-Core+release-13.01"
            | "++Ares-Core+release-13.02"
            | "++Ares-Core+release-13.04"
            | "++Ares-Core+release-13.05"
            | "++Ares-Core+release-13.06" => Self::ALL,
            _ => Self::NONE,
        }
    }

    /// Whether `route` may expand its parent on this branch.
    pub(super) fn admits(self, route: MeasuredArrayRoute) -> bool {
        self.0 & route.bit() != 0
    }
}

#[cfg(test)]
mod tests {
    use super::MeasuredArrayRoute as Route;
    use super::MeasuredArrayRoutes;
    use Route::{
        ActiveBlinds, AllPlayersObfuscatedPlayerInformation as PlayerInfo, KillData,
        NetworkedProjectilePath as ProjectilePath, RequestedIgnoreActors, SelectedV2,
        ServerActiveEffects, TrackedRewards,
    };

    const ALL: &[Route] = &[
        PlayerInfo,
        TrackedRewards,
        SelectedV2,
        KillData,
        ServerActiveEffects,
        RequestedIgnoreActors,
        ActiveBlinds,
        ProjectilePath,
    ];
    /// 11.06: the path is unobserved and SelectedV2's layout differs.
    const B1106: &[Route] = &[KillData, ServerActiveEffects, RequestedIgnoreActors];
    /// 11.07-11.08: SelectedV2's nested attachment handle moved.
    const B1107: &[Route] = &[
        KillData,
        ServerActiveEffects,
        RequestedIgnoreActors,
        ProjectilePath,
    ];
    /// 11.09-12.03: the OwnerExclusivePlayerInfo handles are shifted by +3.
    const B1109: &[Route] = &[
        SelectedV2,
        KillData,
        ServerActiveEffects,
        RequestedIgnoreActors,
        ProjectilePath,
    ];
    /// 12.04-12.09: everything but ActiveBlinds.
    const B1204: &[Route] = &[
        PlayerInfo,
        TrackedRewards,
        SelectedV2,
        KillData,
        ServerActiveEffects,
        RequestedIgnoreActors,
        ProjectilePath,
    ];
    /// 12.06-12.07: no projectile path in any sample.
    const B1206: &[Route] = &[
        PlayerInfo,
        TrackedRewards,
        SelectedV2,
        KillData,
        ServerActiveEffects,
        RequestedIgnoreActors,
    ];
    /// 12.10, 12.11 and 13.00: the only four routes their one fixture holds.
    const FIXTURE: &[Route] = &[PlayerInfo, TrackedRewards, SelectedV2, ServerActiveEffects];

    /// Every supported branch and the routes it admits, in the order of
    /// `vrf_transform::ALL_VERSIONS`. A change to the gate is a change to this
    /// table, made together with the measurement that justifies it.
    const PINNED: &[(&str, &[Route])] = &[
        ("++Ares-Core+release-11.06", B1106),
        ("++Ares-Core+release-11.07", B1107),
        ("++Ares-Core+release-11.08", B1107),
        ("++Ares-Core+release-11.09", B1109),
        ("++Ares-Core+release-11.10", B1109),
        ("++Ares-Core+release-11.11", B1109),
        ("++Ares-Core+release-12.00", B1109),
        ("++Ares-Core+release-12.01", B1109),
        ("++Ares-Core+release-12.02", B1109),
        ("++Ares-Core+release-12.03", B1109),
        ("++Ares-Core+release-12.04", B1204),
        ("++Ares-Core+release-12.05", B1204),
        ("++Ares-Core+release-12.06", B1206),
        ("++Ares-Core+release-12.07", B1206),
        ("++Ares-Core+release-12.08", B1204),
        ("++Ares-Core+release-12.09", B1204),
        ("++Ares-Core+release-12.10", FIXTURE),
        ("++Ares-Core+release-12.11", FIXTURE),
        ("++Ares-Core+release-13.00", FIXTURE),
        ("++Ares-Core+release-13.01", ALL),
        ("++Ares-Core+release-13.02", ALL),
        ("++Ares-Core+release-13.04", ALL),
        ("++Ares-Core+release-13.05", ALL),
        ("++Ares-Core+release-13.06", ALL),
    ];

    #[test]
    fn routes_are_pinned_for_every_supported_branch() {
        // One row per supported branch: a newly supported build must be
        // placed in the table deliberately, even if it admits nothing.
        let supported: Vec<&str> = vrf_transform::ALL_VERSIONS
            .iter()
            .map(|version| version.branch())
            .collect();
        let pinned: Vec<&str> = PINNED.iter().map(|(branch, _)| *branch).collect();
        assert_eq!(pinned, supported);

        for (branch, routes) in PINNED {
            let admitted = MeasuredArrayRoutes::for_branch(branch);
            for route in Route::ALL {
                assert_eq!(
                    admitted.admits(route),
                    routes.contains(&route),
                    "{branch}: {route:?}"
                );
            }
        }
    }

    #[test]
    fn unknown_branches_admit_no_route() {
        for branch in [
            "",
            "13.05",
            "++Ares-Core+release-13.07",
            "++Ares-Core+release-12.12",
            "++Ares-Core+release-13.05 ",
        ] {
            let admitted = MeasuredArrayRoutes::for_branch(branch);
            assert_eq!(admitted, MeasuredArrayRoutes::NONE, "{branch:?}");
            for route in Route::ALL {
                assert!(!admitted.admits(route), "{branch:?}: {route:?}");
            }
        }
    }
}

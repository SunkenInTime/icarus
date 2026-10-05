//! The JSON document of docs/replay-format.md, as serde types. Optional
//! fields are skipped when absent, so "absent" and "null" never disagree.

use std::collections::BTreeMap;

use serde::Serialize;

pub type Vec3 = [f64; 3];

/// `[timeMs, health, armor]`.
pub type VitalsRow = (i64, f64, f64);

/// `[timeMs, x, y, z]`: like every row, its time is an integer.
pub type PathRow = (i64, f64, f64, f64);

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
    pub decoder: Decoder,
    #[serde(rename = "match")]
    pub match_: Match,
    pub players: Vec<Player>,
    pub rounds: Vec<Round>,
    pub kills: Vec<Kill>,
    /// subject -> `[timeMs, health, armor]` rows.
    pub vitals: BTreeMap<String, Vec<VitalsRow>>,
    pub utility: Vec<Utility>,
    pub casts: Vec<Cast>,
    pub movement: BTreeMap<String, MovementSpan>,
    pub quality: Quality,
}

#[derive(Debug, Serialize)]
pub struct Decoder {
    pub name: &'static str,
    pub version: &'static str,
    pub vrfkit: &'static str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Match {
    pub id: String,
    pub map_path: Option<String>,
    pub build: String,
    pub duration_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recorded_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub game_mode: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Player {
    pub subject: String,
    pub agent_id: Option<String>,
    pub team: Option<String>,
    pub character_guids: Vec<u32>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Round {
    pub index: u32,
    pub start_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub combat_start_ms: Option<i64>,
    pub end_ms: i64,
    pub attacking_team: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub winning_team: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_reason: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plant: Option<Plant>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub defuse: Option<Defuse>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detonate_ms: Option<i64>,
    pub economy: Vec<Economy>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plant {
    pub time_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub site: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position: Option<Vec3>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Defuse {
    pub time_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Economy {
    pub subject: String,
    pub credits: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub weapon: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub armor: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Kill {
    pub time_ms: i64,
    pub victim: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub killer: Option<String>,
    pub assists: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub damage_source: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Utility {
    pub id: u32,
    pub class_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    pub spawn_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_ms: Option<i64>,
    pub position: Vec3,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub yaw: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<Vec<PathRow>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub points: Option<Vec<Vec3>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Cast {
    pub time_ms: i64,
    pub subject: String,
    /// `AbilityCastsThisRound[].Slot`: 3 grenade, 4 ability one, 5 ability
    /// two, 9 ultimate (docs/replay-format.md).
    pub slot: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub class_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position: Option<Vec3>,
}

#[derive(Debug, Serialize, Clone, Copy)]
pub struct MovementSpan {
    pub offset: u64,
    pub count: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Quality {
    pub transform_verified: bool,
    /// Typed field decodes that failed (vrfkit's `overlay.decoded_err`).
    pub decode_errors: u64,
    pub loss: Loss,
    pub warnings: Vec<String>,
}

/// What the replication stream lost, as vrfkit's `validate` verdict counts
/// it (`vrf_net::stats::NetStats`). No two count the same bunch or block.
#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Loss {
    /// Packets abandoned part-read (`malformed_packets`).
    pub malformed_packets: u64,
    /// Bunches whose header did not read (`bunch_header_failures`).
    pub bunch_header_failures: u64,
    /// Content blocks whose payload reached no field or RPC
    /// (`lost_content_blocks()`): a payload kept whole is not lost.
    pub lost_content_blocks: u64,
    /// Partial-bunch fragments refused during reassembly, at a resource
    /// limit included (`partial_errors`).
    pub rejected_partials: u64,
    /// Partial bunches still incomplete when the stream ended
    /// (`unfinished_partials`).
    pub unfinished_partials: u64,
    /// Bunches refused at a channel-state limit
    /// (`channel_state_limit_failures`).
    pub refused_bunches: u64,
    /// Bunches on a channel with no open actor, dropped whole
    /// (`bunches_on_unopened_channel`).
    pub unopened_channel_bunches: u64,
    /// Package-map export bunches, whose content after the exports is not
    /// read (`package_map_exports`).
    pub package_map_export_bunches: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn row_times_serialize_as_integers() {
        let utility = Utility {
            id: 1,
            class_path:
                "/Game/Characters/Clay/S0/Ability_E/Pawn_Clay_E_Boomba.Pawn_Clay_E_Boomba_C"
                    .to_owned(),
            owner: None,
            spawn_ms: 50_000,
            end_ms: None,
            position: [0.0, 0.0, 0.0],
            yaw: Some(0.0),
            path: Some(vec![(50_806, 1.5, -2.0, 3.0)]),
            points: None,
        };
        let json = serde_json::to_string(&utility).unwrap();
        assert!(json.contains("[50806,1.5,-2.0,3.0]"), "{json}");
        let back: serde_json::Value = serde_json::from_str(&json).unwrap();
        let row = &back["path"][0];
        assert!(row[0].is_i64(), "{row}");
        assert_eq!(row[0].as_i64(), Some(50_806));

        let vitals: VitalsRow = (1203, 100.0, 50.0);
        let back: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&vitals).unwrap()).unwrap();
        assert!(back[0].is_i64(), "{back}");
    }
}

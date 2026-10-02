//! The JSON document of docs/replay-format.md, as serde types. Optional
//! fields are skipped when absent, so "absent" and "null" never disagree.

use std::collections::BTreeMap;

use serde::Serialize;

pub type Vec3 = [f64; 3];

/// `[timeMs, health, armor]`.
pub type VitalsRow = (i64, Option<f64>, Option<f64>);

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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
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
    pub loadout_value: Option<i64>,
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
    pub path: Option<Vec<[f64; 4]>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub points: Option<Vec<Vec3>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Cast {
    pub time_ms: i64,
    pub subject: String,
    /// The replicated `AbilityCastsThisRound[].Slot` value.
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
    pub decode_errors: u64,
    pub warnings: Vec<String>,
}

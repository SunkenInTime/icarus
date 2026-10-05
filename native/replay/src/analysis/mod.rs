//! Decoded stream -> the document of docs/replay-format.md. vrfkit derives
//! these views in Python under `tools/`; each module here names the tool its
//! rules come from, and departs from it only where it says so.

mod casts;
mod kills;
mod movement;
mod rounds;
mod utility;
mod vitals;

use std::collections::{BTreeMap, HashMap};

use vrf_container::Preamble;
use vrf_schema::NetGuidCache;

use crate::collect::{Collector, Row};
use crate::decode::Walked;
use crate::document::{Decoder, Document, Loss, Match, Player, Quality, Vec3};
use crate::guard::GuardVerdict;
use crate::header::{self, DECODER_VERSION, VRFKIT_VERSION};

/// Everything the analysis reads, indexed once.
pub(crate) struct Context<'a> {
    pub rows: &'a [Row],
    pub events: &'a [vrf_export::EventRecord],
    pub actors: &'a [vrf_export::ActorRecord],
    pub cache: &'a NetGuidCache,
    pub duration_ms: i64,
    pub players: Vec<PlayerIdentity>,
    /// Pawn NetGUID -> subject, for every unambiguous `SpawnedCharacter`.
    pub body_subject: HashMap<u32, String>,
    /// PlayerState NetGUID -> subject.
    pub state_subject: HashMap<u32, String>,
    /// Actor NetGUID -> class path, from its first open naming one.
    pub actor_class: HashMap<u32, String>,
    /// Actor NetGUID -> `Owner` / `Instigator` writes `(time, value)`, in order.
    pub owner_writes: HashMap<u32, Vec<(u32, u32)>>,
    pub instigator_writes: HashMap<u32, Vec<(u32, u32)>>,
    pub warnings: Vec<String>,
}

pub(crate) struct PlayerIdentity {
    pub subject: String,
    pub state: u32,
    pub bodies: Vec<u32>,
}

impl<'a> Context<'a> {
    fn new(collector: &'a Collector, walked: &'a Walked, duration_ms: i64) -> Self {
        let mut warnings = Vec::new();

        // tools/player_identity.py: a pawn named by exactly one PlayerState's
        // `SpawnedCharacter` history is that player's body; vrfkit's sink
        // keeps the history (`PlayerIdentity::character_net_guids`).
        let mut players: Vec<PlayerIdentity> = walked
            .players
            .iter()
            .filter_map(|(&state, identity)| {
                Some(PlayerIdentity {
                    subject: identity.subject.as_ref()?.to_ascii_lowercase(),
                    state,
                    bodies: identity.character_net_guids.clone(),
                })
            })
            .collect();
        players.sort_by_key(|p| p.state);
        let unnamed = walked
            .players
            .values()
            .filter(|p| p.subject.is_none())
            .count();
        if unnamed > 0 {
            warnings.push(format!(
                "{unnamed} PlayerState(s) never replicated a Subject"
            ));
        }
        let mut claims: HashMap<u32, Vec<&str>> = HashMap::new();
        for p in &players {
            for &body in &p.bodies {
                claims.entry(body).or_default().push(&p.subject);
            }
        }
        let mut body_subject = HashMap::new();
        for (body, subjects) in claims {
            if subjects.len() == 1 {
                body_subject.insert(body, subjects[0].to_owned());
            } else {
                warnings.push(format!(
                    "pawn {body} is claimed by {} players; left unattributed",
                    subjects.len()
                ));
            }
        }
        let state_subject = players
            .iter()
            .map(|p| (p.state, p.subject.clone()))
            .collect();

        let mut actor_class = HashMap::new();
        for a in &collector.actors {
            if let Some(class) = &a.class_path {
                actor_class
                    .entry(a.actor_net_guid)
                    .or_insert_with(|| class.clone());
            }
        }
        let mut owner_writes: HashMap<u32, Vec<(u32, u32)>> = HashMap::new();
        let mut instigator_writes: HashMap<u32, Vec<(u32, u32)>> = HashMap::new();
        for row in &collector.rows {
            // Only the actor's own property, not a subobject's.
            if row.object.is_some() {
                continue;
            }
            let Some(value) = row.int.and_then(|v| u32::try_from(v).ok()) else {
                continue;
            };
            match &*row.name {
                "Owner" => owner_writes
                    .entry(row.actor)
                    .or_default()
                    .push((row.time, value)),
                "Instigator" => instigator_writes
                    .entry(row.actor)
                    .or_default()
                    .push((row.time, value)),
                _ => {}
            }
        }

        Self {
            rows: &collector.rows,
            events: &collector.events,
            actors: &collector.actors,
            cache: &walked.cache,
            duration_ms,
            players,
            body_subject,
            state_subject,
            actor_class,
            owner_writes,
            instigator_writes,
            warnings,
        }
    }

    /// The player behind `guid` at `time`: the guid itself when it is a
    /// body, else whoever owns it, following `Owner` then `Instigator` up to
    /// four hops (a smoke's manager is owned by the pawn). Like
    /// tools/extract_spike_carrier.py's proxy walk, but not limited to one hop.
    pub fn subject_behind(&self, guid: u32, time: u32) -> Option<&str> {
        self.subject_behind_depth(guid, time, 4)
    }

    fn subject_behind_depth(&self, guid: u32, time: u32, depth: u32) -> Option<&str> {
        if let Some(subject) = self.body_subject.get(&guid) {
            return Some(subject);
        }
        if depth == 0 || guid == 0 {
            return None;
        }
        for writes in [&self.owner_writes, &self.instigator_writes] {
            if let Some(next) = writes.get(&guid).and_then(|w| value_at(w, time)) {
                if next != guid {
                    if let Some(subject) = self.subject_behind_depth(next, time, depth - 1) {
                        return Some(subject);
                    }
                }
            }
        }
        None
    }

    /// The class path of an actor, else the GUID table's path.
    pub fn class_of(&self, guid: u32) -> Option<String> {
        self.actor_class
            .get(&guid)
            .cloned()
            .or_else(|| self.cache.get_path_by_guid(guid).map(str::to_owned))
    }
}

/// The last non-zero value written at or before `time`; failing that, the
/// first non-zero value written (an actor's owner arrives in its open packet,
/// which can carry a later `time_ms` than the event asking).
pub(crate) fn value_at(writes: &[(u32, u32)], time: u32) -> Option<u32> {
    writes
        .iter()
        .rev()
        .find(|&&(t, v)| t <= time && v != 0)
        .or_else(|| writes.iter().find(|&&(_, v)| v != 0))
        .map(|&(_, v)| v)
}

/// `(x,y,z)` as vrfkit renders a VectorDouble.
pub(crate) fn parse_vector(text: &str) -> Option<Vec3> {
    let inner = text.trim().strip_prefix('(')?.strip_suffix(')')?;
    let mut parts = inner.split(',').map(|p| p.trim().parse::<f64>().ok());
    let v = [parts.next()??, parts.next()??, parts.next()??];
    (parts.next().is_none() && v.iter().all(|c| c.is_finite())).then_some(v)
}

/// A vector parameter vrfkit leaves untyped: 192 bits, three little-endian
/// f64 (UE5's double `FVector`). Typed so only where a field's values were
/// checked against the world: Fast Lane's points step 125 cm along a line
/// from the actor, Shear's start is its actor's spawn, Barrier Mesh's
/// `RootLocation` is its root's.
pub(crate) fn raw_vector(raw: &[u8]) -> Option<Vec3> {
    if raw.len() != 24 {
        return None;
    }
    let f = |i: usize| f64::from_le_bytes(raw[i..i + 8].try_into().expect("8 bytes"));
    let v = [f(0), f(8), f(16)];
    v.iter().all(|c| c.is_finite()).then_some(v)
}

/// The result of the analysis: the JSON document and the movement blob.
pub struct Analysed {
    pub document: Document,
    pub blob: Vec<u8>,
}

pub(crate) fn analyse(
    preamble: &Preamble,
    collector: &Collector,
    walked: &Walked,
    guard: GuardVerdict,
) -> Analysed {
    let probe = header::Probe::from_preamble(preamble);
    let mut cx = Context::new(collector, walked, probe.duration_ms);

    let agents: HashMap<String, Option<String>> = probe
        .players
        .iter()
        .map(|p| (p.subject.clone(), p.agent_id.clone()))
        .collect();
    let teams = team_by_subject(&cx);
    let players: Vec<Player> = cx
        .players
        .iter()
        .map(|p| Player {
            subject: p.subject.clone(),
            agent_id: agents.get(&p.subject).cloned().flatten(),
            team: teams.get(&p.subject).cloned(),
            character_guids: p.bodies.clone(),
        })
        .collect();
    for p in &players {
        if p.agent_id.is_none() {
            cx.warnings.push(format!(
                "player {} has no agent in the header's playerLoadouts",
                p.subject
            ));
        }
        if p.team.is_none() {
            cx.warnings.push(format!(
                "player {} has no team in any combat report",
                p.subject
            ));
        }
    }

    let rounds = rounds::rounds(&mut cx);
    let kills = kills::kills(&mut cx, &teams);
    let vitals = vitals::vitals(&mut cx, &rounds);
    let utility = utility::utility(
        &mut cx,
        &collector.moves,
        rounds.first().map(|r| r.start_ms),
    );
    let casts = casts::casts(&mut cx, &rounds);
    let (movement, blob) = movement::movement(&mut cx, &collector.moves);

    let stats = &walked.stats;
    let net = &walked.net;
    let loss = Loss {
        malformed_packets: net.malformed_packets,
        bunch_header_failures: net.bunch_header_failures,
        lost_content_blocks: net.lost_content_blocks(),
        rejected_partials: net.partial_errors,
        unfinished_partials: net.unfinished_partials,
        refused_bunches: net.channel_state_limit_failures,
        unopened_channel_bunches: net.bunches_on_unopened_channel,
        package_map_export_bunches: net.package_map_exports,
    };
    let mut warnings = std::mem::take(&mut cx.warnings);
    for (name, value) in [
        ("malformed packets", loss.malformed_packets),
        (
            "bunch headers that did not read",
            loss.bunch_header_failures,
        ),
        ("content blocks lost", loss.lost_content_blocks),
        ("partial bunch fragments rejected", loss.rejected_partials),
        ("partial bunches unfinished", loss.unfinished_partials),
        ("bunches refused at a channel limit", loss.refused_bunches),
        (
            "bunches on unopened channels",
            loss.unopened_channel_bunches,
        ),
        (
            "package-map export bunches",
            loss.package_map_export_bunches,
        ),
        ("movement decode errors", stats.movement_rpc_errors),
        ("struct-blob decode failures", stats.struct_blobs_failed),
        ("array leaf decode errors", stats.array_leaf_decode_errors),
        ("unknown chunks", u64::from(walked.unknown_chunks)),
        (
            "event chunks off the measured layout",
            u64::from(walked.event_layout_mismatches),
        ),
    ] {
        if value > 0 {
            warnings.push(format!("{value} {name}"));
        }
    }

    let document = Document {
        decoder: Decoder {
            name: "icarus_replay",
            version: DECODER_VERSION,
            vrfkit: VRFKIT_VERSION,
        },
        match_: Match {
            id: probe.id,
            map_path: probe.map_path,
            build: probe.build,
            duration_ms: probe.duration_ms,
            recorded_at: probe.recorded_at,
            game_mode: game_mode(
                walked
                    .cache
                    .net_guid_entries()
                    .iter()
                    .map(|e| (e.path, e.outer_net_guid)),
                &walked.cache,
            ),
        },
        players,
        rounds,
        kills,
        vitals,
        utility,
        casts,
        movement,
        quality: Quality {
            transform_verified: guard.verified,
            decode_errors: stats.overlay.decoded_err,
            loss,
            warnings,
        },
    };
    Analysed { document, blob }
}

/// Team per subject from the combat reports: every `Interactions[i]`
/// element names a participant's subject and team (`ParticipantSubject`,
/// `ParticipantTeamName`). Teams are fixed for a match (sides swap, teams do
/// not), so a subject reported on two teams is a conflict and stays absent.
fn team_by_subject(cx: &Context<'_>) -> BTreeMap<String, String> {
    // (component actor, element indices) -> (subject, team), last write wins.
    /// (subject, team) as last written.
    type Participant = (Option<String>, Option<String>);
    let mut elements: HashMap<(u32, Vec<Option<u32>>), Participant> = HashMap::new();
    for row in cx.rows {
        let path = crate::fieldpath::FieldPath::parse(&row.name);
        if path.segments.first().map(|s| s.base) != Some("Rounds") {
            continue;
        }
        let slot = elements.entry((row.actor, path.indices())).or_default();
        match path.leaf() {
            "ParticipantSubject" => slot.0 = row.text.as_ref().map(|s| s.to_ascii_lowercase()),
            "ParticipantTeamName" => slot.1 = row.text.clone(),
            _ => {}
        }
    }
    let mut seen: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (subject, team) in elements.into_values() {
        if let (Some(subject), Some(team)) = (subject, team) {
            if team == "Red" || team == "Blue" {
                let teams = seen.entry(subject).or_default();
                if !teams.contains(&team) {
                    teams.push(team);
                }
            }
        }
    }
    seen.into_iter()
        .filter(|(_, teams)| teams.len() == 1)
        .map(|(subject, mut teams)| (subject, teams.remove(0)))
        .collect()
}

/// The game mode class, `/Game/GameModes/<..>/<X>GameMode.<X>GameMode_C`,
/// from the GUID table (the game state names it as a dependency).
fn game_mode<'p>(
    entries: impl Iterator<Item = (&'p str, Option<u32>)>,
    cache: &NetGuidCache,
) -> Option<String> {
    for (path, outer) in entries {
        if !path.ends_with("GameMode_C") || path.contains('/') {
            continue;
        }
        let Some(outer_path) = outer.and_then(|o| cache.get_path_by_guid(o)) else {
            continue;
        };
        if outer_path.starts_with("/Game/GameModes/") {
            return Some(format!("{outer_path}.{path}"));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vectors_parse_as_vrfkit_renders_them() {
        assert_eq!(parse_vector("(1.5,-2,3e2)"), Some([1.5, -2.0, 300.0]));
        assert_eq!(parse_vector("(1,2)"), None);
        assert_eq!(parse_vector("(1,2,3,4)"), None);
        assert_eq!(parse_vector("1,2,3"), None);
        assert_eq!(parse_vector("(NaN,0,0)"), None);
    }

    #[test]
    fn untyped_vectors_are_three_little_endian_doubles() {
        // A Fast Lane point from c8989335, as its 24 payload bytes.
        let mut raw = Vec::new();
        for v in [6081.25_f64, -4858.5, 210.0] {
            raw.extend(v.to_le_bytes());
        }
        assert_eq!(raw_vector(&raw), Some([6081.25, -4858.5, 210.0]));
        assert_eq!(raw_vector(&raw[..16]), None, "two doubles are not a vector");
        raw[..8].copy_from_slice(&f64::NAN.to_le_bytes());
        assert_eq!(raw_vector(&raw), None);
    }

    #[test]
    fn owner_lookup_prefers_the_last_prior_non_zero_write() {
        let writes = [(10, 5), (20, 0), (30, 7)];
        assert_eq!(value_at(&writes, 25), Some(5));
        assert_eq!(value_at(&writes, 30), Some(7));
        assert_eq!(
            value_at(&writes, 5),
            Some(5),
            "falls back to the first write"
        );
        assert_eq!(value_at(&[(1, 0)], 5), None);
    }
}

//! vrfkit's field names for array members, `Rounds[2].Reports[0].Interactions[1].ParticipantSubject`
//! or `AbilityCastsThisRound[0].CastTime_4_5AE288704801A9B74D6D159DFC2BD147`,
//! split into segments with the Blueprint member suffix (`_<n>_<32 hex>`) dropped.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Segment<'a> {
    pub base: &'a str,
    pub index: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldPath<'a> {
    pub segments: Vec<Segment<'a>>,
}

impl<'a> FieldPath<'a> {
    pub fn parse(name: &'a str) -> Self {
        let segments = name
            .split('.')
            .map(|part| {
                let (head, index) = match part.find('[') {
                    Some(open) if part.ends_with(']') => {
                        (&part[..open], part[open + 1..part.len() - 1].parse().ok())
                    }
                    _ => (part, None),
                };
                Segment {
                    base: strip_blueprint_suffix(head),
                    index,
                }
            })
            .collect();
        Self { segments }
    }

    /// The last segment's base name.
    pub fn leaf(&self) -> &'a str {
        self.segments.last().map_or("", |s| s.base)
    }

    /// The indices of every segment but the last, in order.
    pub fn indices(&self) -> Vec<Option<u32>> {
        self.segments[..self.segments.len().saturating_sub(1)]
            .iter()
            .map(|s| s.index)
            .collect()
    }
}

/// `CastTime_4_5AE288704801A9B74D6D159DFC2BD147` -> `CastTime`.
fn strip_blueprint_suffix(name: &str) -> &str {
    let Some((head, hex)) = name.rsplit_once('_') else {
        return name;
    };
    if hex.len() != 32 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return name;
    }
    match head.rsplit_once('_') {
        Some((base, n)) if !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()) => base,
        _ => name,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blueprint_members_and_indices_split() {
        let p = FieldPath::parse(
            "AbilityCastsThisRound[3].CastTime_4_5AE288704801A9B74D6D159DFC2BD147",
        );
        assert_eq!(
            p.segments[0],
            Segment {
                base: "AbilityCastsThisRound",
                index: Some(3)
            }
        );
        assert_eq!(p.leaf(), "CastTime");
        assert_eq!(p.indices(), vec![Some(3)]);
    }

    #[test]
    fn plain_names_are_untouched() {
        let p = FieldPath::parse("MulticastNotifyDamage_Point.LifeChangeEvents[1].LifeResult");
        assert_eq!(p.segments[0].base, "MulticastNotifyDamage_Point");
        assert_eq!(
            p.segments[1],
            Segment {
                base: "LifeChangeEvents",
                index: Some(1)
            }
        );
        assert_eq!(p.leaf(), "LifeResult");
        assert_eq!(FieldPath::parse("Money").leaf(), "Money");
        // A trailing `_<n>` alone is part of the name.
        assert_eq!(FieldPath::parse("MyEquippable_0").leaf(), "MyEquippable_0");
    }
}

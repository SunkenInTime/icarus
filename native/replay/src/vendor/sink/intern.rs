// Vendored from vrfkit v0.2.5 (c4d6cc0), crates/vrfkit/src/sink/intern.rs. Apache-2.0;
// see native/replay/NOTICE.md. Local edits: listed in src/vendor/mod.rs.

//! A string pool for the two name columns of `fields.parquet`: a row's name
//! costs a refcount, not an allocation (the lookup still hashes), and buffered
//! rows share one copy. Arrow sees only `&str`, so the Parquet bytes do not
//! depend on it. Counts: docs/PERFORMANCE_NOTES.md#name-interning.

use std::fmt::Write as _;
use std::sync::Arc;

use vrf_schema::FxHashSet;

/// Ceiling on pooled names, a bound on wire-driven input: an unnamed RPC
/// parameter is `"{function}._h{handle}"` with the handle off the wire. Past the
/// cap `intern` still returns a correct, unshared `Arc<str>`. The reference
/// replay pools 4,557 names.
const MAX_POOLED_NAMES: usize = 65_536;

/// Pool of interned names, plus the scratch buffer [`Self::intern_fmt`] builds
/// them in so no caller allocates a `String` only to throw it away.
#[derive(Debug, Clone, Default)]
pub struct NameInterner {
    pool: FxHashSet<Arc<str>>,
    scratch: String,
}

impl NameInterner {
    /// Pool `s` and return the shared handle.
    pub fn intern(&mut self, s: &str) -> Arc<str> {
        pooled(&mut self.pool, s)
    }

    /// Build a name with `f` in the scratch buffer, then pool it: the
    /// allocation-free path for the composed names (RPC parameters, array
    /// leaves, struct-blob members), which are the majority of rows.
    pub fn intern_fmt(&mut self, f: impl FnOnce(&mut String)) -> Arc<str> {
        let Self { pool, scratch } = self;
        scratch.clear();
        f(scratch);
        pooled(pool, scratch)
    }

    /// Number of distinct names currently pooled. Diagnostic only.
    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.pool.len()
    }
}

/// The pooled handle for `s`, pooled now if it is new and the pool is under
/// [`MAX_POOLED_NAMES`].
fn pooled(pool: &mut FxHashSet<Arc<str>>, s: &str) -> Arc<str> {
    if let Some(existing) = pool.get(s) {
        return Arc::clone(existing);
    }
    let interned: Arc<str> = Arc::from(s);
    if pool.len() < MAX_POOLED_NAMES {
        pool.insert(Arc::clone(&interned));
    }
    interned
}

/// Write `args` into `out`. A `String` write cannot fail, and `let _ = write!`
/// at each call site would read as an ignored error.
pub fn put(out: &mut String, args: std::fmt::Arguments<'_>) {
    out.write_fmt(args)
        .expect("formatting into a String cannot fail");
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Equal text shares one allocation; `Arc::ptr_eq` is how to observe it.
    #[test]
    fn equal_names_share_one_allocation() {
        let mut interner = NameInterner::default();
        let a = interner.intern("/Script/ShooterGame.ShooterCharacter");
        let b = interner.intern("/Script/ShooterGame.ShooterCharacter");
        assert!(Arc::ptr_eq(&a, &b));
        assert_eq!(interner.len(), 1);
    }

    /// The built-in-place path must agree with the plain one, including sharing.
    #[test]
    fn a_formatted_name_pools_with_its_plain_twin() {
        let mut interner = NameInterner::default();
        let plain = interner.intern("Fire.Damage");
        let built = interner.intern_fmt(|out| put(out, format_args!("Fire.{}", "Damage")));
        assert_eq!(&*built, "Fire.Damage");
        assert!(Arc::ptr_eq(&plain, &built));
        assert_eq!(interner.len(), 1);
    }

    /// Past the cap the pool stops growing but `intern` still returns the
    /// right text: a name storm costs sharing, never correctness.
    #[test]
    fn the_pool_stops_growing_but_never_stops_being_correct() {
        let mut interner = NameInterner::default();
        for i in 0..(MAX_POOLED_NAMES + 64) {
            let name = interner.intern_fmt(|out| put(out, format_args!("Fn._h{i}")));
            assert_eq!(&*name, format!("Fn._h{i}"));
        }
        assert_eq!(interner.len(), MAX_POOLED_NAMES);
        // A name minted after the cap is still correct, just unshared.
        let over = interner.intern("a name the pool never saw");
        assert_eq!(&*over, "a name the pool never saw");
    }
}

use convex_sync_types::{
    types::ErrorPayload,
    QueryId,
    Timestamp,
};
use imbl::{
    OrdMap,
    OrdSet,
};

use super::SubscriberId;
use crate::{
    ConvexError,
    Value,
};

/// Result of a Convex function (query/mutation/action).
///
/// The function returns a Convex value or an error message string.
#[derive(Clone, Eq, PartialEq)]
pub enum FunctionResult {
    /// The Convex value returned on a successful run of a Convex function
    Value(Value),
    /// The error message of a Convex function run that does not complete
    /// successfully.
    ErrorMessage(String),
    /// The error payload of a Convex function run that doesn't complete
    /// successfully, with an application-level error.
    ConvexError(ConvexError),
}

impl From<Result<Value, ErrorPayload<Value>>> for FunctionResult {
    fn from(result: Result<Value, ErrorPayload<Value>>) -> Self {
        match result {
            Ok(value) => FunctionResult::Value(value),
            Err(ErrorPayload::ErrorData { message, data }) => {
                FunctionResult::ConvexError(ConvexError { message, data })
            },
            Err(ErrorPayload::Message(message)) => FunctionResult::ErrorMessage(message),
        }
    }
}

impl From<FunctionResult> for Result<Value, ErrorPayload<Value>> {
    fn from(result: FunctionResult) -> Self {
        match result {
            FunctionResult::Value(value) => Ok(value),
            FunctionResult::ErrorMessage(error) => Err(ErrorPayload::Message(error)),
            FunctionResult::ConvexError(error) => Err(ErrorPayload::ErrorData {
                message: error.message,
                data: error.data,
            }),
        }
    }
}

impl std::fmt::Debug for FunctionResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FunctionResult::Value(value) => f.debug_tuple("Value").field(value).finish(),
            FunctionResult::ErrorMessage(error) => write!(f, "{error}"),
            FunctionResult::ConvexError(error) => {
                f.debug_tuple("ConvexError").field(error).finish()
            },
        }
    }
}

/// A query result with the snapshot it comes from, as
/// [`QueryResults::timed`] gives it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TimedResult {
    /// The query's result: a value or an error.
    pub value: FunctionResult,
    /// The server time of the snapshot, as [`QueryResults::ts`].
    pub ts: Option<Timestamp>,
    /// The snapshot's number in this client, as [`QueryResults::snapshot`]:
    /// the higher of two is the newer, and equal numbers mean the same result.
    pub snapshot: u64,
    /// The connection, as [`QueryResults::connection`].
    pub connection: u64,
    /// The client, as [`QueryResults::client`].
    pub client: u64,
}

/// A mapping from [`SubscriberId`] to its current result [`FunctionResult`]
/// for each actively subscribed query.
#[derive(Clone, Default, Debug)]
pub struct QueryResults {
    pub(super) results: OrdMap<QueryId, FunctionResult>,
    pub(super) subscribers: OrdSet<SubscriberId>,
    pub(super) ts: Option<Timestamp>,
    pub(super) snapshot: u64,
    pub(super) connection: u64,
    pub(super) client: u64,
}

impl QueryResults {
    /// The server time of the snapshot these results come from: the end
    /// timestamp of the last transition the client applied. Every result in
    /// it carries this timestamp, a value that last changed earlier included.
    /// `None` before the first transition.
    ///
    /// Two snapshots can share a timestamp (a transition can end at the time
    /// the one before it ended), so the timestamp alone does not order two
    /// results of one query. [`QueryResults::snapshot`] does.
    pub fn ts(&self) -> Option<Timestamp> {
        self.ts
    }

    /// How many transitions this client had applied when these results were
    /// taken: 0 before the first. It counts up by one with every transition,
    /// across reconnects, and restarts only with the client. Results with the
    /// same number come from one snapshot, which holds one result per query,
    /// so two results of one query with the same number are the same result,
    /// and the one with the higher number is the newer.
    pub fn snapshot(&self) -> u64 {
        self.snapshot
    }

    /// The connection these results were taken on: 0 for the client's first
    /// socket, one more for each reconnect. Results kept from an earlier
    /// connection carry its number until the new connection's first
    /// transition replaces them.
    pub fn connection(&self) -> u64 {
        self.connection
    }

    /// The client these results come from, numbered from 1 in the order
    /// clients are built in this process. Snapshots of different clients do
    /// not compare.
    pub fn client(&self) -> u64 {
        self.client
    }

    /// The result for [`SubscriberId`], with the snapshot it comes from.
    pub fn timed(&self, subscriber_id: &SubscriberId) -> Option<TimedResult> {
        self.get(subscriber_id)
            .map(|value| self.stamped(value.clone()))
    }

    /// [`value`] with this snapshot's stamp.
    pub(super) fn stamped(&self, value: FunctionResult) -> TimedResult {
        TimedResult {
            value,
            ts: self.ts,
            snapshot: self.snapshot,
            connection: self.connection,
            client: self.client,
        }
    }

    /// Get the [`FunctionResult`] for the given [`SubscriberId`]
    pub fn get(&self, subscriber_id: &SubscriberId) -> Option<&FunctionResult> {
        if !self.subscribers.contains(subscriber_id) {
            return None;
        };
        self.results.get(&subscriber_id.0)
    }

    /// Get the size of the map.
    pub fn len(&self) -> usize {
        self.subscribers.len()
    }

    /// Test whether the map is empty.
    pub fn is_empty(&self) -> bool {
        self.subscribers.is_empty()
    }

    /// Get an iterator over the subscriber_id/query_result pairs of the map.
    pub fn iter(&self) -> impl Iterator<Item = (&SubscriberId, Option<&FunctionResult>)> {
        self.subscribers.iter().map(|s| (s, self.results.get(&s.0)))
    }
}

#[cfg(test)]
mod tests {
    use convex_sync_types::QueryId;
    use imbl::{
        ordmap,
        ordset,
    };

    use crate::{
        base_client::SubscriberId,
        FunctionResult,
        QueryResults,
        Value,
    };

    #[test]
    fn test_query_results() {
        let q = QueryId::new;
        let s = SubscriberId;

        let qr = QueryResults {
            results: ordmap! {
                q(0) => FunctionResult::Value(Value::Null),
                q(1) => FunctionResult::Value(Value::Int64(5))
            },
            subscribers: ordset! {
                s(q(0), 0),
                s(q(0), 1),
                s(q(1), 0),
                s(q(2), 0)
            },
            ts: None,
            snapshot: 0,
            connection: 0,
            client: 0,
        };
        assert_eq!(
            qr.get(&s(q(0), 0)),
            Some(&FunctionResult::Value(Value::Null))
        );
        assert_eq!(
            qr.get(&s(q(0), 1)),
            Some(&FunctionResult::Value(Value::Null))
        );
        assert_eq!(
            qr.get(&s(q(1), 0)),
            Some(&FunctionResult::Value(Value::Int64(5)))
        );
        assert_eq!(qr.get(&s(q(2), 0)), None,);
        assert_eq!(qr.len(), 4);
        assert!(!qr.is_empty());
        let v: Vec<_> = qr.iter().collect();
        assert_eq!(
            v,
            vec![
                (&s(q(0), 0), Some(&FunctionResult::Value(Value::Null))),
                (&s(q(0), 1), Some(&FunctionResult::Value(Value::Null))),
                (&s(q(1), 0), Some(&FunctionResult::Value(Value::Int64(5)))),
                (&s(q(2), 0), None),
            ],
        );
    }
}

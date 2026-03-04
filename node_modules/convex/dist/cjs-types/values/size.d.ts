/**
 * Calculate the size of a Convex value in bytes.
 *
 * This matches the Rust implementation in crates/value/src/ which is used
 * to compute bandwidth and document size limits.
 *
 * Size formula by type:
 * - Null: 1 byte (type marker)
 * - Boolean: 1 byte (type marker, value stored in marker)
 * - Int64 (bigint): 9 bytes (1 type marker + 8 bytes for 64-bit value)
 * - Float64 (number): 9 bytes (1 type marker + 8 bytes for 64-bit value)
 * - String: 2 + string.length bytes (1 type marker + UTF-8 bytes + 1 null terminator)
 * - Bytes (ArrayBuffer): 2 + bytes.length bytes (1 type marker + bytes + 1 terminator)
 * - Array: 2 + sum(element sizes) bytes (1 type marker + elements + 1 terminator)
 * - Object: 2 + sum(field_name.length + 1 + value.size) bytes
 *           (1 type marker + (field_name + null terminator + value)* + 1 terminator)
 *
 * For documents with system fields (_id and _creationTime), the size includes:
 * - _id field: 4 bytes (field name + null) + string size (2 + 31+ chars)
 * - _creationTime field: 14 bytes (field name + null) + 9 bytes (Float64)
 *
 * @module
 */
import type { Value } from "./value.js";
/**
 * Calculate the size in bytes of a Convex value.
 *
 * This matches how Convex calculates document size for bandwidth tracking
 * and size limit enforcement.
 *
 * @param value - A Convex value to measure
 * @returns The size in bytes
 *
 * @public
 */
export declare function getConvexSize(value: Value): number;
export declare const SYSTEM_FIELD_ID_ESTIMATE = 38;
export declare const SYSTEM_FIELD_CREATION_TIME_SIZE = 23;
/**
 * Calculate the size of a document including system fields.
 *
 * If your value already has _id and _creationTime fields, this will count them
 * in the normal size calculation. Otherwise, it adds the constant overhead
 * for system fields.
 *
 * @param value - A Convex object (document body)
 * @param options - Options for size calculation
 * @returns The size in bytes
 *
 * @public
 */
export declare function getDocumentSize(value: Record<string, Value>, options?: {}): number;
//# sourceMappingURL=size.d.ts.map
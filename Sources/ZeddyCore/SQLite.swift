import Foundation
import SQLiteShim

/// Thin, defensive wrapper over libsqlite3 (via the `SQLiteShim` C target).
///
/// We deliberately keep this small: a prepared-statement loop with bound
/// values and a column reader. Everything Zeddy needs (FTS5, bm25) is a SQL
/// feature, not a C API, so no extra surface is required here.
public enum SQLite {
    public static let ok: Int32 = Int32(ZEDDY_OK)
    public static let row: Int32 = Int32(ZEDDY_ROW)
    public static let done: Int32 = Int32(ZEDDY_DONE)

    public struct Error: Swift.Error, CustomStringConvertible {
        public let code: Int32
        public let message: String
        public var description: String { "SQLite error (\(code)): \(message)" }
    }

    /// An open database handle. Closes the handle on deinit.
    public final class Connection: @unchecked Sendable {
        private let db: OpaquePointer

        public init(path: String) throws {
            var handle: OpaquePointer?
            let rc = zeddy_open((path as NSString).utf8String, &handle)
            guard rc == Int32(ZEDDY_OK), let handle else {
                let msg = handle.map { String(cString: zeddy_errmsg($0)) } ?? "open failed (\(rc))"
                if let handle { zeddy_close(handle) }
                throw Error(code: Int32(rc), message: msg)
            }
            self.db = handle
            // Tolerate concurrent readers (GUI + daemon sharing one file).
            zeddy_busy_timeout(handle, 5_000)
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA synchronous=NORMAL;")
            try exec("PRAGMA temp_store=MEMORY;")
            try exec("PRAGMA mmap_size=67108864;")
            try exec("PRAGMA cache_size=-32000;")
        }

        deinit {
            zeddy_close(db)
        }

        public var libraryVersion: String { String(cString: zeddy_version()) }

        private func msg() -> String { String(cString: zeddy_errmsg(db)) }

        /// Runs `sql` (one or more `;`-separated statements) with no binds.
        public func exec(_ sql: String) throws {
            let utf8 = (sql as NSString).utf8String
            let len = Int32(-1) // strlen; exec is used for DDL/PRAGMA (null-terminated)
            var tail: UnsafePointer<CChar>?
            var stmt: OpaquePointer?
            let rc = zeddy_prepare(db, utf8, len, &stmt, &tail)
            guard rc == Int32(ZEDDY_OK) else { throw Error(code: Int32(rc), message: msg()) }
            while let s = stmt {
                let step = zeddy_step(s)
                if step == Int32(ZEDDY_ROW) || step == Int32(ZEDDY_DONE) {
                    if tail == nil { break }
                    zeddy_reset(s)
                    zeddy_finalize(s)
                    let next = tail!
                    var cur: OpaquePointer?
                    let r2 = zeddy_prepare(db, next, len, &cur, &tail)
                    guard r2 == Int32(ZEDDY_OK) else {
                        if let cur { zeddy_finalize(cur) }
                        throw Error(code: Int32(r2), message: msg())
                    }
                    stmt = cur
                } else if step == Int32(ZEDDY_OK) {
                    zeddy_finalize(s)
                    break
                } else {
                    zeddy_finalize(s)
                    throw Error(code: Int32(step), message: msg())
                }
            }
        }

        /// Binds `params` (1-based) and runs to completion. Returns changes.
        ///
        /// The change count is `@discardableResult` because most write callers
        /// (e.g. FTS sync) don't need it; callers that do (upsert) use it.
        @discardableResult
        public func run(_ sql: String, _ params: [Any?]) throws -> Int {

            let utf8 = (sql as NSString).utf8String
            let len = Int32(sql.utf8.count)
            var tail: UnsafePointer<CChar>?
            var stmt: OpaquePointer?
            let rc = zeddy_prepare(db, utf8, len, &stmt, &tail)
            guard rc == Int32(ZEDDY_OK), let stmt else {
                throw Error(code: Int32(rc), message: msg())
            }
            defer { zeddy_finalize(stmt) }
            for (i, value) in params.enumerated() {
                try bind(stmt, i + 1, value)
            }
            let step = zeddy_step(stmt)
            if step != Int32(ZEDDY_DONE) && step != Int32(ZEDDY_ROW) {
                throw Error(code: Int32(step), message: msg())
            }
            return Int(zeddy_changes(db))
        }

        /// Steps through every result row, invoking `consume` per row.
        /// Returns the number of rows consumed (often ignored by callers).
        @discardableResult
        public func query(
            _ sql: String,
            _ params: [Any?],
            _ consume: (Row) throws -> Void
        ) throws -> Int {
            let utf8 = (sql as NSString).utf8String
            let len = Int32(sql.utf8.count)
            var tail: UnsafePointer<CChar>?

            var stmt: OpaquePointer?

            let rc = zeddy_prepare(db, utf8, len, &stmt, &tail)

            guard rc == Int32(ZEDDY_OK), let stmt else {

                throw Error(code: Int32(rc), message: msg())

            }

            defer { zeddy_finalize(stmt) }

            for (i, value) in params.enumerated() {

                try bind(stmt, i + 1, value)

            }

            var count = 0
            while true {
                let step = zeddy_step(stmt)
                if step == Int32(ZEDDY_ROW) {
                    count += 1
                    try consume(Row(stmt: stmt))
                } else if step == Int32(ZEDDY_DONE) {
                    break
                } else {
                    throw Error(code: Int32(step), message: msg())
                }
            }
            return count
        }

        private func bind(_ stmt: OpaquePointer, _ index: Int, _ value: Any?) throws {
            let idx = Int32(index)
            let rc: Int32
            switch value {
            case nil:
                rc = Int32(zeddy_bind_null(stmt, idx))
            case let s as String:
                // Direct UTF-8 byte access without NSString bridging overhead.
                rc = s.utf8.withContiguousStorageIfAvailable { buf in
                    zeddy_bind_text(stmt, idx, buf.baseAddress, Int32(buf.count))
                } ?? s.withCString { cStr in
                    zeddy_bind_text(stmt, idx, cStr, Int32(s.utf8.count))
                }
            case let i as Int:
                rc = Int32(zeddy_bind_int64(stmt, idx, Int64(i)))
            case let i as Int64:
                rc = Int32(zeddy_bind_int64(stmt, idx, i))
            case let d as Double:
                rc = Int32(zeddy_bind_double(stmt, idx, d))
            case let d as Date:
                rc = Int32(zeddy_bind_double(stmt, idx, d.timeIntervalSince1970))
            case let data as Data:
                if data.isEmpty {
                    rc = Int32(zeddy_bind_null(stmt, idx))
                } else {
                    rc = Int32(data.withUnsafeBytes { ptr in
                        zeddy_bind_blob(stmt, idx, ptr.baseAddress, Int32(ptr.count))
                    })
                }
            case let number as NSNumber:
                if String(cString: number.objCType) == "d" {
                    rc = Int32(zeddy_bind_double(stmt, idx, number.doubleValue))
                } else {
                    rc = Int32(zeddy_bind_int64(stmt, idx, number.int64Value))
                }
            default:
                throw Error(code: -1, message: "unsupported bind type: \(type(of: value))")
            }
            guard rc == Int32(ZEDDY_OK) else { throw Error(code: rc, message: msg()) }
        }
    }

    /// A single result row; read values by 0-based column index.
    public struct Row {
        let stmt: OpaquePointer
        public let columnCount: Int

        init(stmt: OpaquePointer) {
            self.stmt = stmt
            self.columnCount = Int(zeddy_column_count(stmt))
        }

        public subscript(_ index: Int) -> Any? {
            let type = Int(zeddy_column_type(stmt, Int32(index)))
            switch type {
            case Int(ZEDDY_COL_NULL):
                return nil
            case Int(ZEDDY_COL_INT):
                return Int(zeddy_column_int64(stmt, Int32(index)))
            case Int(ZEDDY_COL_REAL):
                return zeddy_column_double(stmt, Int32(index))
            case Int(ZEDDY_COL_TEXT):
                if let p = zeddy_column_text(stmt, Int32(index)) {
                    let bytes = Int(zeddy_column_bytes(stmt, Int32(index)))
                    return String(decoding: UnsafeBufferPointer(start: p, count: bytes), as: UTF8.self)
                }
                return ""
            case Int(ZEDDY_COL_BLOB):
                if let p = zeddy_column_blob(stmt, Int32(index)) {
                    let bytes = Int(zeddy_column_bytes(stmt, Int32(index)))
                    return Data(bytes: p.assumingMemoryBound(to: UInt8.self), count: bytes)
                }
                return Data()
            default:
                return nil
            }
        }

        public func int(_ i: Int) -> Int { self[i] as? Int ?? 0 }
        public func int64(_ i: Int) -> Int64 { Int64(int(i)) }
        public func double(_ i: Int) -> Double { self[i] as? Double ?? 0 }
        public func string(_ i: Int) -> String? { self[i] as? String }
        public func data(_ i: Int) -> Data? { self[i] as? Data }
    }
}

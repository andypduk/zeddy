#ifndef ZEDDY_H
#define ZEDDY_H

#include <sqlite3.h>

/*
 * A thin, purpose-named shim over the vendored libsqlite3.
 *
 * The Swift side (ZeddyCore/SQLite.swift) wraps exactly the handful of
 * statements it needs; everything else (FTS5, bm25, ...) is expressed as SQL.
 * The `ZEDDY_*` result codes and column types are `enum` constants (not
 * #define) because Clang imports anonymous C enums as `Int32` globals
 * reliably, whereas plain `#define`'d names are not always imported.
 */

enum {
    ZEDDY_OK   = 0,   // SQLITE_OK
    ZEDDY_ROW  = 100, // SQLITE_ROW
    ZEDDY_DONE = 101  // SQLITE_DONE
};

enum {
    ZEDDY_COL_NULL = 0, // SQLITE_NULL
    ZEDDY_COL_INT  = 1, // SQLITE_INT
    ZEDDY_COL_REAL = 2, // SQLITE_REAL
    ZEDDY_COL_TEXT = 3, // SQLITE_TEXT
    ZEDDY_COL_BLOB = 4  // SQLITE_BLOB
};

/* Lifecycle */
int  zeddy_open(const char *path, struct sqlite3 **db);
void zeddy_close(struct sqlite3 *db);
void zeddy_busy_timeout(struct sqlite3 *db, int ms);

/* Info / diagnostics */
const char *zeddy_version(void);
const char *zeddy_errmsg(struct sqlite3 *db);

/* Statement lifecycle */
int  zeddy_prepare(struct sqlite3 *db, const char *sql, int len,
                   struct sqlite3_stmt **stmt, const char **tail);
int  zeddy_step(struct sqlite3_stmt *stmt);
int  zeddy_reset(struct sqlite3_stmt *stmt);
int  zeddy_finalize(struct sqlite3_stmt *stmt);
int  zeddy_changes(struct sqlite3 *db);

/* Binds. Text/blob bind with SQLITE_TRANSIENT so libsqlite3 copies the bytes;
 * the caller's buffers are Swift-managed and may be freed right after. */
int  zeddy_bind_null(struct sqlite3_stmt *stmt, int i);
int  zeddy_bind_text(struct sqlite3_stmt *stmt, int i, const char *z, int n);
int  zeddy_bind_int64(struct sqlite3_stmt *stmt, int i, long long v);
int  zeddy_bind_double(struct sqlite3_stmt *stmt, int i, double v);
int  zeddy_bind_blob(struct sqlite3_stmt *stmt, int i, const void *p, int n);

/* Column readers (0-based column index). */
int  zeddy_column_count(struct sqlite3_stmt *stmt);
int  zeddy_column_type(struct sqlite3_stmt *stmt, int i);
long long zeddy_column_int64(struct sqlite3_stmt *stmt, int i);
double zeddy_column_double(struct sqlite3_stmt *stmt, int i);
const unsigned char *zeddy_column_text(struct sqlite3_stmt *stmt, int i);
int  zeddy_column_bytes(struct sqlite3_stmt *stmt, int i);
const void *zeddy_column_blob(struct sqlite3_stmt *stmt, int i);

#endif

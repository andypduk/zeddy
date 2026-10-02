#include "zeddy.h"
#include <sqlite3.h>

/*
 * Implementation of the zeddy_* shim. Each function is a near-1:1 mapping onto
 * libsqlite3; the only behavioural choices that matter are:
 *   - zeddy_open uses READWRITE|CREATE (the store always owns its file).
 *   - text/blob binds use SQLITE_TRANSIENT so libsqlite3 copies the bytes.
 *   - null-safety on handles so a torn-down handle can't crash the daemon.
 */

int zeddy_open(const char *path, struct sqlite3 **db) {
    if (!path || !db) return -1;
    return sqlite3_open_v2(path, db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
}

void zeddy_close(struct sqlite3 *db) {
    if (db) sqlite3_close(db);
}

void zeddy_busy_timeout(struct sqlite3 *db, int ms) {
    if (db) sqlite3_busy_timeout(db, ms);
}

const char *zeddy_version(void) {
    return sqlite3_libversion();
}

const char *zeddy_errmsg(struct sqlite3 *db) {
    if (!db) return "no database handle";
    const char *msg = sqlite3_errmsg(db);
    return msg ? msg : "unknown error";
}

int zeddy_prepare(struct sqlite3 *db, const char *sql, int len,
                  struct sqlite3_stmt **stmt, const char **tail) {
    if (!db || !sql) return -1;
    return sqlite3_prepare_v2(db, sql, len, stmt, tail);
}

int zeddy_step(struct sqlite3_stmt *stmt) {
    if (!stmt) return -1;
    return sqlite3_step(stmt);
}

int zeddy_reset(struct sqlite3_stmt *stmt) {
    if (!stmt) return -1;
    return sqlite3_reset(stmt);
}

int zeddy_finalize(struct sqlite3_stmt *stmt) {
    if (!stmt) return -1;
    return sqlite3_finalize(stmt);
}

int zeddy_changes(struct sqlite3 *db) {
    if (!db) return 0;
    return sqlite3_changes(db);
}

int zeddy_bind_null(struct sqlite3_stmt *stmt, int i) {
    if (!stmt) return -1;
    return sqlite3_bind_null(stmt, i);
}

int zeddy_bind_text(struct sqlite3_stmt *stmt, int i, const char *z, int n) {
    if (!stmt) return -1;
    return sqlite3_bind_text(stmt, i, z, n, SQLITE_TRANSIENT);
}

int zeddy_bind_int64(struct sqlite3_stmt *stmt, int i, long long v) {
    if (!stmt) return -1;
    return sqlite3_bind_int64(stmt, i, v);
}

int zeddy_bind_double(struct sqlite3_stmt *stmt, int i, double v) {
    if (!stmt) return -1;
    return sqlite3_bind_double(stmt, i, v);
}

int zeddy_bind_blob(struct sqlite3_stmt *stmt, int i, const void *p, int n) {
    if (!stmt) return -1;
    return sqlite3_bind_blob(stmt, i, p, n, SQLITE_TRANSIENT);
}

int zeddy_column_count(struct sqlite3_stmt *stmt) {
    if (!stmt) return 0;
    return sqlite3_column_count(stmt);
}

int zeddy_column_type(struct sqlite3_stmt *stmt, int i) {
    if (!stmt) return -1;
    return sqlite3_column_type(stmt, i);
}

long long zeddy_column_int64(struct sqlite3_stmt *stmt, int i) {
    if (!stmt) return 0;
    return sqlite3_column_int64(stmt, i);
}

double zeddy_column_double(struct sqlite3_stmt *stmt, int i) {
    if (!stmt) return 0.0;
    return sqlite3_column_double(stmt, i);
}

const unsigned char *zeddy_column_text(struct sqlite3_stmt *stmt, int i) {
    if (!stmt) return NULL;
    return sqlite3_column_text(stmt, i);
}

int zeddy_column_bytes(struct sqlite3_stmt *stmt, int i) {
    if (!stmt) return 0;
    return sqlite3_column_bytes(stmt, i);
}

const void *zeddy_column_blob(struct sqlite3_stmt *stmt, int i) {
    if (!stmt) return NULL;
    return sqlite3_column_blob(stmt, i);
}

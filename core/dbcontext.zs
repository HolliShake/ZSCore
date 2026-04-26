

// Capture SQLite's Database class before the mysql import shadows the name.
import "core:sqlite";
const _SqliteDB = sqlite.Database;

// MySQL / MariaDB Database class (overwrites `Database` name above — intentional).
import "core:mysql";
const _MysqlDB = mysql.Database;

import { replace } from "core:string";
import { Object  } from "core:object";
import { format  } from "core:io";
import { Model   } from "./base";

// ─────────────────────────────────────────────────────────────────────────────
//  DbContext
//  Unified database adapter wrapping either SQLite3 (core:sqlite) or
//  MySQL / MariaDB (core:mysql).  Exposes the interface that QueryBuilder in
//  core/base.zs expects:
//      select · aggregate · insert · update · delete · increment
//
//  SQLite:
//      const db = new DbContext({ type: "sqlite", path: "app.sqlite" });
//      // Omit `path` or pass ":memory:" for an in-memory database.
//
//  MySQL / MariaDB:
//      const db = new DbContext({
//          type:     "mysql",
//          host:     "127.0.0.1",
//          user:     "root",
//          password: "secret",
//          database: "tinylms",
//          port:     3306          // optional, defaults to 3306
//      });
//
//  Wire to the ORM:
//      Model.setDB(db);
//
//  Raw DDL:
//      db.exec("CREATE TABLE IF NOT EXISTS ...");
//
//  Transactions:
//      db.beginTransaction();
//      db.commitTransaction();   // or db.rollbackTransaction();
// ─────────────────────────────────────────────────────────────────────────────

class DbContext {

    fn init(options) {
        this._type       = options.type;
        this._conn       = null;
        this._cache      = {};   // MySQL only: table → [columnName, …] schema cache
        this._migrations = [];   // Populated by the derived AppDbContext subclass
        this._connect(options);
        // Automatically register this context as the ORM connection so every
        // Model instance created after this point uses it via Model._connection.
        Model.setDB(this);
    }

    // ── Connection ────────────────────────────────────────────────────────────

    fn _connect(options) {
        if (this._type == "sqlite") {
            local path = options.path;
            if (path == null) path = ":memory:";
            this._conn = new _SqliteDB(path);

        } else if (this._type == "mysql") {
            this._conn = new _MysqlDB({
                host:     options.host,
                user:     options.user,
                password: options.password,
                database: options.database,
                port:     options.port != null ? options.port : 3306
            });

        } else {
            raise format("DbContext: unsupported driver '{}'", this._type);
        }
    }

    fn close() {
        if (this._conn != null) {
            this._conn.close();
            this._conn = null;
        }
    }

    // ── Raw DDL / migrations ──────────────────────────────────────────────────

    fn exec(sql) {
        return this._conn.exec(sql);
    }

    // ── Transactions ──────────────────────────────────────────────────────────

    fn beginTransaction() {
        if (this._type == "sqlite") {
            this._conn.exec("BEGIN");
        } else {
            this._conn.exec("START TRANSACTION");
        }
    }

    fn commitTransaction() {
        this._conn.exec("COMMIT");
    }

    fn rollbackTransaction() {
        this._conn.exec("ROLLBACK");
    }

    // ── MySQL helpers ─────────────────────────────────────────────────────────

    // Embed a scalar value safely into a MySQL SQL string.
    fn _escape(val) {
        if (val == null)  return "NULL";
        if (val == true)  return "1";
        if (val == false) return "0";
        local s = replace(val + "", "\\", "\\\\");
        s = replace(s, "'",  "\\'");
        s = replace(s, "\n", "\\n");
        s = replace(s, "\r", "\\r");
        s = replace(s, "\0", "\\0");
        return "'" + s + "'";
    }

    // Fetch and cache a MySQL table's column order via SHOW COLUMNS.
    // SHOW COLUMNS rows use numeric string keys; "0" is the Field (name).
    fn _mysqlColumnNames(table) {
        if (this._cache[table] != null) return this._cache[table];
        local rows = this._conn.query("SHOW COLUMNS FROM `" + table + "`");
        local cols = [];
        local i    = 0;
        while (i < rows.length()) {
            cols.push(rows[i]["0"]);
            i = i + 1;
        }
        this._cache[table] = cols;
        return cols;
    }

    // Re-key MySQL numeric-indexed rows to named-column objects.
    // When a specific column list was SELECTed (not "*"), those names are used
    // directly to skip the SHOW COLUMNS round-trip.
    fn _mysqlRemap(table, rows, selectCols) {
        if (rows.length() == 0) return rows;

        local cols;
        if (selectCols != null && selectCols.length() > 0 && selectCols[0] != "*") {
            cols = selectCols;
        } else {
            cols = this._mysqlColumnNames(table);
        }

        local out = [];
        local i   = 0;
        while (i < rows.length()) {
            local src = rows[i];
            local obj = {};
            local j   = 0;
            while (j < cols.length()) {
                obj[cols[j]] = src[j + ""];
                j = j + 1;
            }
            out.push(obj);
            i = i + 1;
        }
        return out;
    }

    // ── Condition builder (shared by WHERE and HAVING) ────────────────────────
    //
    // For SQLite  → returns { sql, bindings } where sql uses @wN named params.
    //               Caller merges bindings and passes the object to stmt.run/get/all.
    // For MySQL   → returns { sql } with values already escaped inline.
    //
    // Supported operators:
    //   = != < > <= >= LIKE   IN   NOT IN
    //   IS NULL   IS NOT NULL    BETWEEN
    //   raw (pass { raw: "…", bindings: {…} } for arbitrary SQL)
    //
    // paramOffset: start index for @wN names (avoids collisions when
    //              WHERE and HAVING share the same bindings object).

    fn _buildConditions(conditions, isSqlite, paramOffset) {
        if (conditions == null || conditions.length() == 0) {
            return { sql: "", bindings: {} };
        }
        if (paramOffset == null) paramOffset = 0;

        local parts    = [];
        local bindings = {};
        local pIdx     = paramOffset;
        local first    = true;
        local i        = 0;

        while (i < conditions.length()) {
            local c    = conditions[i];
            local bool = c.boolean;
            if (bool == null) bool = "AND";
            local prefix = first ? "" : (" " + bool + " ");
            first = false;

            if (c.raw != null) {
                parts.push(prefix + c.raw);
                if (isSqlite && c.bindings != null) {
                    local bkeys = Object.keys(c.bindings);
                    local k = 0;
                    while (k < bkeys.length()) {
                        bindings[bkeys[k]] = c.bindings[bkeys[k]];
                        k = k + 1;
                    }
                }

            } else if (c.op == "IN" || c.op == "NOT IN") {
                local listSql = "";
                local k = 0;
                while (k < c.value.length()) {
                    if (k > 0) listSql = listSql + ", ";
                    if (isSqlite) {
                        local pname = "w" + pIdx; pIdx = pIdx + 1;
                        listSql = listSql + "@" + pname;
                        bindings[pname] = c.value[k];
                    } else {
                        listSql = listSql + this._escape(c.value[k]);
                    }
                    k = k + 1;
                }
                parts.push(prefix + "`" + c.column + "` " + c.op + " (" + listSql + ")");

            } else if (c.op == "IS NULL" || c.op == "IS NOT NULL") {
                parts.push(prefix + "`" + c.column + "` " + c.op);

            } else if (c.op == "BETWEEN") {
                if (isSqlite) {
                    local p1 = "w" + pIdx; pIdx = pIdx + 1;
                    local p2 = "w" + pIdx; pIdx = pIdx + 1;
                    parts.push(prefix + "`" + c.column + "` BETWEEN @" + p1 + " AND @" + p2);
                    bindings[p1] = c.value[0];
                    bindings[p2] = c.value[1];
                } else {
                    parts.push(prefix + "`" + c.column + "` BETWEEN " +
                               this._escape(c.value[0]) + " AND " + this._escape(c.value[1]));
                }

            } else {
                if (isSqlite) {
                    local pname = "w" + pIdx; pIdx = pIdx + 1;
                    parts.push(prefix + "`" + c.column + "` " + c.op + " @" + pname);
                    bindings[pname] = c.value;
                } else {
                    parts.push(prefix + "`" + c.column + "` " + c.op + " " + this._escape(c.value));
                }
            }
            i = i + 1;
        }

        local sql = "";
        local j   = 0;
        while (j < parts.length()) {
            sql = sql + parts[j];
            j   = j + 1;
        }
        return { sql: sql, bindings: bindings };
    }

    // ── SELECT SQL builder ────────────────────────────────────────────────────

    fn _buildSelectSQL(p, isSqlite) {
        // Column list
        local selStr = "*";
        if (p.selects != null && p.selects.length() > 0 && p.selects[0] != "*") {
            selStr = "";
            local k = 0;
            while (k < p.selects.length()) {
                if (k > 0) selStr = selStr + ", ";
                selStr = selStr + "`" + p.selects[k] + "`";
                k = k + 1;
            }
        }

        local sql = "SELECT " + selStr + " FROM `" + p.table + "`";

        // JOINs — each entry is { type, table, localKey, foreignKey }
        if (p.joins != null && p.joins.length() > 0) {
            local k = 0;
            while (k < p.joins.length()) {
                local jn = p.joins[k];
                sql = sql + " " + jn.type +
                      " `" + jn.table + "` ON `" + p.table + "`.`" + jn.localKey +
                      "` = `" + jn.table + "`.`" + jn.foreignKey + "`";
                k = k + 1;
            }
        }

        // WHERE — pIdx starts at 0
        local whereResult   = this._buildConditions(p.wheres, isSqlite, 0);
        local allBindings   = whereResult.bindings;
        if (whereResult.sql != "") sql = sql + " WHERE " + whereResult.sql;

        // GROUP BY
        if (p.groups != null && p.groups.length() > 0) {
            sql = sql + " GROUP BY ";
            local k = 0;
            while (k < p.groups.length()) {
                if (k > 0) sql = sql + ", ";
                sql = sql + "`" + p.groups[k] + "`";
                k = k + 1;
            }
        }

        // HAVING — pIdx starts at 1000 to avoid clashing with WHERE bindings
        if (p.havings != null && p.havings.length() > 0) {
            local hResult = this._buildConditions(p.havings, isSqlite, 1000);
            if (hResult.sql != "") {
                sql = sql + " HAVING " + hResult.sql;
                if (isSqlite) {
                    local hkeys = Object.keys(hResult.bindings);
                    local k     = 0;
                    while (k < hkeys.length()) {
                        allBindings[hkeys[k]] = hResult.bindings[hkeys[k]];
                        k = k + 1;
                    }
                }
            }
        }

        // ORDER BY — each entry is { column, direction }
        if (p.orders != null && p.orders.length() > 0) {
            sql = sql + " ORDER BY ";
            local k = 0;
            while (k < p.orders.length()) {
                if (k > 0) sql = sql + ", ";
                sql = sql + "`" + p.orders[k].column + "` " + p.orders[k].direction;
                k = k + 1;
            }
        }

        // LIMIT / OFFSET — always numeric, safe to embed directly
        if (p.limit  != null) sql = sql + " LIMIT "  + p.limit;
        if (p.offset != null) sql = sql + " OFFSET " + p.offset;

        return { sql: sql, bindings: allBindings };
    }

    // ── SQLite execution helpers ──────────────────────────────────────────────

    fn _sqliteRun(sql, bindings) {
        local stmt = this._conn.prepare(sql);
        local info;
        if (Object.keys(bindings).length() == 0) {
            info = stmt.run();
        } else {
            info = stmt.run(bindings);
        }
        stmt.finalize();
        return info;
    }

    fn _sqliteGet(sql, bindings) {
        local stmt = this._conn.prepare(sql);
        local row;
        if (Object.keys(bindings).length() == 0) {
            row = stmt.get();
        } else {
            row = stmt.get(bindings);
        }
        stmt.finalize();
        return row;
    }

    fn _sqliteAll(sql, bindings) {
        local stmt = this._conn.prepare(sql);
        local rows;
        if (Object.keys(bindings).length() == 0) {
            rows = stmt.all();
        } else {
            rows = stmt.all(bindings);
        }
        stmt.finalize();
        return rows;
    }

    // ── Public query interface (called by QueryBuilder) ───────────────────────

    fn select(p) async {
        local isSqlite = this._type == "sqlite";
        local built    = this._buildSelectSQL(p, isSqlite);

        if (isSqlite) {
            return this._sqliteAll(built.sql, built.bindings);
        } else {
            local rows = this._conn.query(built.sql);
            return this._mysqlRemap(p.table, rows, p.selects);
        }
    }

    fn aggregate(p) async {
        local isSqlite = this._type == "sqlite";
        local agCol    = p.aggregateColumn != null ? ("`" + p.aggregateColumn + "`") : "*";
        local agExpr   = p.aggregate + "(" + agCol + ") AS result";

        local whereResult = this._buildConditions(p.wheres, isSqlite, 0);
        local sql = "SELECT " + agExpr + " FROM `" + p.table + "`";
        if (whereResult.sql != "") sql = sql + " WHERE " + whereResult.sql;

        if (isSqlite) {
            local row = this._sqliteGet(sql, whereResult.bindings);
            return row != null ? row : { result: 0 };
        } else {
            local rows = this._conn.query(sql);
            return rows.length() > 0 ? { result: rows[0]["0"] } : { result: 0 };
        }
    }

    fn insert(p) async {
        local isSqlite = this._type == "sqlite";
        local cols     = Object.keys(p.data);
        if (cols.length() == 0) raise "DbContext.insert: data object is empty";

        local colList = "";
        local k = 0;
        while (k < cols.length()) {
            if (k > 0) colList = colList + ", ";
            colList = colList + "`" + cols[k] + "`";
            k = k + 1;
        }

        if (isSqlite) {
            // @colname placeholders — pass p.data directly as named bindings.
            local valList = "";
            local k2 = 0;
            while (k2 < cols.length()) {
                if (k2 > 0) valList = valList + ", ";
                valList = valList + "@" + cols[k2];
                k2 = k2 + 1;
            }
            local sql  = "INSERT INTO `" + p.table + "` (" + colList + ") VALUES (" + valList + ")";
            local info = this._sqliteRun(sql, p.data);
            return { insertId: info.lastInsertRowid, changes: info.changes };

        } else {
            local valList = "";
            local k2 = 0;
            while (k2 < cols.length()) {
                if (k2 > 0) valList = valList + ", ";
                valList = valList + this._escape(p.data[cols[k2]]);
                k2 = k2 + 1;
            }
            local sql  = "INSERT INTO `" + p.table + "` (" + colList + ") VALUES (" + valList + ")";
            local info = this._conn.exec(sql);
            return { insertId: info.insertId, changes: info.affectedRows };
        }
    }

    fn update(p) async {
        local isSqlite = this._type == "sqlite";
        local cols     = Object.keys(p.data);
        if (cols.length() == 0) return { changes: 0 };

        local setClause   = "";
        local setBindings = {};

        local k = 0;
        while (k < cols.length()) {
            if (k > 0) setClause = setClause + ", ";
            if (isSqlite) {
                // Prefix data params with "d_" to avoid collisions with WHERE params.
                local pname = "d_" + cols[k];
                setClause = setClause + "`" + cols[k] + "` = @" + pname;
                setBindings[pname] = p.data[cols[k]];
            } else {
                setClause = setClause + "`" + cols[k] + "` = " + this._escape(p.data[cols[k]]);
            }
            k = k + 1;
        }

        local whereResult = this._buildConditions(p.wheres, isSqlite, 0);
        local sql = "UPDATE `" + p.table + "` SET " + setClause;
        if (whereResult.sql != "") sql = sql + " WHERE " + whereResult.sql;

        if (isSqlite) {
            local bindings = { ...setBindings, ...whereResult.bindings };
            local info     = this._sqliteRun(sql, bindings);
            return { changes: info.changes };
        } else {
            local info = this._conn.exec(sql);
            return { changes: info.affectedRows };
        }
    }

    fn delete(p) async {
        local isSqlite    = this._type == "sqlite";
        local whereResult = this._buildConditions(p.wheres, isSqlite, 0);
        local sql         = "DELETE FROM `" + p.table + "`";
        if (whereResult.sql != "") sql = sql + " WHERE " + whereResult.sql;

        if (isSqlite) {
            local info = this._sqliteRun(sql, whereResult.bindings);
            return { changes: info.changes };
        } else {
            local info = this._conn.exec(sql);
            return { changes: info.affectedRows };
        }
    }

    fn increment(p) async {
        local isSqlite  = this._type == "sqlite";
        local bindings  = {};
        local setExpr;

        if (isSqlite) {
            setExpr = "`" + p.column + "` = `" + p.column + "` + @_inc";
            bindings["_inc"] = p.amount;
        } else {
            setExpr = "`" + p.column + "` = `" + p.column + "` + " + this._escape(p.amount);
        }

        local whereResult = this._buildConditions(p.wheres, isSqlite, 0);
        local sql = "UPDATE `" + p.table + "` SET " + setExpr;
        if (whereResult.sql != "") sql = sql + " WHERE " + whereResult.sql;

        if (isSqlite) {
            local allBindings = { ...bindings, ...whereResult.bindings };
            local info        = this._sqliteRun(sql, allBindings);
            return { changes: info.changes };
        } else {
            local info = this._conn.exec(sql);
            return { changes: info.affectedRows };
        }
    }
}
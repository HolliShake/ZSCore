import { ColumnDef } from "./column";

// ─────────────────────────────────────────────────────────────────────────────
//  Blueprint
//  Table schema builder used inside Migration.up() / .down() via SchemaBuilder.
//  All column factory methods return the new ColumnDef so modifiers can be
//  chained:
//
//      schema.create("users", fn(t) {
//          t.id();
//          t.string("email", 191).unique();
//          t.string("password", 255);
//          t.boolean("is_admin").defaultVal(false);
//          t.timestamps();
//      });
//
//  Driver-aware: pass "sqlite" or "mysql" to get the correct SQL dialect.
// ─────────────────────────────────────────────────────────────────────────────

class Blueprint {

    fn init(table, driver) {
        this._table   = table;
        this._driver  = driver;
        this._columns = [];
        this._indexes = [];   // { type: "UNIQUE"|"INDEX", name, columns: [] }
    }

    // ── Internal column factory ───────────────────────────────────────────────

    fn _col(name, type) {
        local col = new ColumnDef(name, type);
        this._columns.push(col);
        return col;
    }

    // ── Primary-key shortcuts ─────────────────────────────────────────────────

    // INTEGER PRIMARY KEY AUTOINCREMENT (SQLite) / INT UNSIGNED AUTO_INCREMENT PRIMARY KEY (MySQL)
    fn id(name) {
        if (name == null) name = "id";
        return this._col(name, "id");
    }

    // Same as id() but uses BIGINT on MySQL
    fn bigId(name) {
        if (name == null) name = "id";
        return this._col(name, "bigId");
    }

    // ── String / text ─────────────────────────────────────────────────────────

    fn string(name, length) {
        local col = this._col(name, "string");
        if (length != null) col._length = length;
        return col;
    }

    fn char(name, length) {
        local col = this._col(name, "char");
        if (length != null) col._length = length;
        return col;
    }

    fn text(name)       { return this._col(name, "text"); }
    fn mediumText(name) { return this._col(name, "mediumText"); }
    fn longText(name)   { return this._col(name, "longText"); }

    // ── Numeric ───────────────────────────────────────────────────────────────

    fn integer(name)      { return this._col(name, "integer"); }
    fn bigInteger(name)   { return this._col(name, "bigInteger"); }
    fn smallInteger(name) { return this._col(name, "smallInteger"); }
    fn tinyInteger(name)  { return this._col(name, "tinyInteger"); }

    fn float(name)  { return this._col(name, "float"); }
    fn double(name) { return this._col(name, "double"); }

    fn decimal(name, precision, scale) {
        local col      = this._col(name, "decimal");
        col._precision = precision != null ? precision : 8;
        col._scale     = scale     != null ? scale     : 2;
        return col;
    }

    // ── Misc ──────────────────────────────────────────────────────────────────

    fn boolean(name) { return this._col(name, "boolean"); }
    fn json(name)    { return this._col(name, "json"); }
    fn blob(name)    { return this._col(name, "binary"); }

    // ── Date / time ───────────────────────────────────────────────────────────

    fn date(name)     { return this._col(name, "date"); }
    fn dateTime(name) { return this._col(name, "dateTime"); }
    fn time(name)     { return this._col(name, "time"); }

    // Stored as BIGINT (Unix ms) — matches the ORM's new Date().getTime()
    fn timestamp(name) { return this._col(name, "timestamp"); }

    // ── Convenience compound helpers ──────────────────────────────────────────

    // Adds created_at + updated_at BIGINT NULL columns (used by ORM timestamps)
    fn timestamps() {
        this._col("created_at", "timestamp").nullable();
        this._col("updated_at", "timestamp").nullable();
    }

    // Adds deleted_at BIGINT NULL column (used by ORM soft deletes)
    fn softDeletes(name) {
        if (name == null) name = "deleted_at";
        return this._col(name, "timestamp").nullable();
    }

    // Foreign-key integer shorthand: bigInteger UNSIGNED + .references(table, col)
    fn foreign(name) {
        return this._col(name, "bigInteger").unsigned();
    }

    // ── Extra index / constraint helpers ──────────────────────────────────────

    // Registers a multi-column UNIQUE constraint (emitted inline in CREATE TABLE)
    fn unique(columns) {
        if (typeof(columns) == "string") columns = [columns];
        this._indexes.push({ type: "UNIQUE", columns: columns });
    }

    // Registers a CREATE INDEX statement (emitted separately via toIndexSqls())
    fn index(columns, name) {
        if (typeof(columns) == "string") columns = [columns];
        if (name == null) name = this._table + "_" + columns[0] + "_index";
        this._indexes.push({ type: "INDEX", name: name, columns: columns });
    }

    // ── SQL generation ────────────────────────────────────────────────────────

    fn toSql() {
        local lines = [];

        // Column definitions
        local i = 0;
        while (i < this._columns.length()) {
            lines.push("    " + this._columns[i].toSqlFragment(this._driver));
            i = i + 1;
        }

        // Table-level FOREIGN KEY constraints
        local j = 0;
        while (j < this._columns.length()) {
            local fk = this._columns[j].toForeignFragment();
            if (fk != null) lines.push("    " + fk);
            j = j + 1;
        }

        // Inline UNIQUE constraints (multi-column)
        local k = 0;
        while (k < this._indexes.length()) {
            local idx = this._indexes[k];
            if (idx.type == "UNIQUE") {
                local cols = "";
                local m    = 0;
                while (m < idx.columns.length()) {
                    if (m > 0) cols = cols + ", ";
                    cols = cols + "`" + idx.columns[m] + "`";
                    m = m + 1;
                }
                lines.push("    UNIQUE (" + cols + ")");
            }
            k = k + 1;
        }

        // Build CREATE TABLE body
        local body = "";
        local n    = 0;
        while (n < lines.length()) {
            if (n > 0) body = body + ",\n";
            body = body + lines[n];
            n = n + 1;
        }

        return "CREATE TABLE IF NOT EXISTS `" + this._table + "` (\n" + body + "\n)";
    }

    fn toDropSql() {
        return "DROP TABLE IF EXISTS `" + this._table + "`";
    }

    // Returns an array of CREATE INDEX statements (executed separately after CREATE TABLE)
    fn toIndexSqls() {
        local sqls = [];
        local i    = 0;
        while (i < this._indexes.length()) {
            local idx = this._indexes[i];
            if (idx.type == "INDEX") {
                local cols = "";
                local m    = 0;
                while (m < idx.columns.length()) {
                    if (m > 0) cols = cols + ", ";
                    cols = cols + "`" + idx.columns[m] + "`";
                    m = m + 1;
                }
                sqls.push("CREATE INDEX IF NOT EXISTS `" + idx.name +
                           "` ON `" + this._table + "` (" + cols + ")");
            }
            i = i + 1;
        }
        return sqls;
    }
}

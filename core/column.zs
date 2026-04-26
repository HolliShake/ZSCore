// ─────────────────────────────────────────────────────────────────────────────
//  ColumnDef
//  Represents a single table column with fluent modifier methods.
//  Created via Blueprint factory methods (Blueprint.string(), .integer(), …)
//  and compiled to a SQL fragment via toSqlFragment(driver).
//
//  Supported logical types:
//      id · bigId · integer · bigInteger · smallInteger · tinyInteger
//      string · char · text · mediumText · longText
//      float · double · decimal
//      boolean · json · blob
//      date · dateTime · time · timestamp
//
//  Fluent modifiers (all return `this` for chaining):
//      .nullable()           — allow NULL
//      .notNull()            — disallow NULL (default)
//      .defaultVal(val)      — column default value
//      .unique()             — add UNIQUE constraint
//      .unsigned()           — UNSIGNED (MySQL only; ignored by SQLite)
//      .autoIncrement()      — AUTO_INCREMENT / AUTOINCREMENT
//      .primary()            — PRIMARY KEY
//      .references(t, col)   — add FOREIGN KEY targeting table.col
// ─────────────────────────────────────────────────────────────────────────────

class ColumnDef {

    fn init(name, type) {
        this._name       = name;
        this._type       = type;   // logical type string
        this._length     = null;   // VARCHAR / CHAR length
        this._precision  = null;   // DECIMAL precision
        this._scale      = null;   // DECIMAL scale
        this._nullable   = false;
        this._defaultVal = null;
        this._hasDefault = false;
        this._unique     = false;
        this._primary    = false;
        this._autoInc    = false;
        this._unsigned   = false;
        this._references = null;   // { table, column }
    }

    // ── Fluent modifiers ──────────────────────────────────────────────────────

    fn nullable() {
        this._nullable = true;
        return this;
    }

    fn notNull() {
        this._nullable = false;
        return this;
    }

    fn defaultVal(val) {
        this._defaultVal = val;
        this._hasDefault = true;
        return this;
    }

    fn unique() {
        this._unique = true;
        return this;
    }

    fn unsigned() {
        this._unsigned = true;
        return this;
    }

    fn autoIncrement() {
        this._autoInc = true;
        return this;
    }

    fn primary() {
        this._primary = true;
        return this;
    }

    fn references(table, column) {
        if (column == null) column = "id";
        this._references = { table: table, column: column };
        return this;
    }

    // ── SQL type mapping ──────────────────────────────────────────────────────

    fn _sqlType(driver) {
        local t = this._type;

        // Primary-key shorthand types
        if (t == "id") {
            if (driver == "mysql") return "INT UNSIGNED";
            return "INTEGER";
        }
        if (t == "bigId") {
            if (driver == "mysql") return "BIGINT UNSIGNED";
            return "INTEGER";
        }

        // Integer family
        if (t == "integer" || t == "int") {
            if (driver == "mysql") {
                if (this._unsigned) return "INT UNSIGNED";
                return "INT";
            }
            return "INTEGER";
        }
        if (t == "bigInteger") {
            if (driver == "mysql") {
                if (this._unsigned) return "BIGINT UNSIGNED";
                return "BIGINT";
            }
            return "INTEGER";
        }
        if (t == "smallInteger") {
            if (driver == "mysql") return "SMALLINT";
            return "INTEGER";
        }
        if (t == "tinyInteger") {
            if (driver == "mysql") return "TINYINT";
            return "INTEGER";
        }

        // String family
        if (t == "string") {
            local len = this._length != null ? this._length : 255;
            return "VARCHAR(" + len + ")";
        }
        if (t == "char") {
            local len = this._length != null ? this._length : 1;
            return "CHAR(" + len + ")";
        }
        if (t == "text")       return "TEXT";
        if (t == "mediumText") {
            if (driver == "mysql") return "MEDIUMTEXT";
            return "TEXT";
        }
        if (t == "longText") {
            if (driver == "mysql") return "LONGTEXT";
            return "TEXT";
        }

        // Floating-point / fixed-point
        if (t == "float") {
            if (driver == "mysql") return "FLOAT";
            return "REAL";
        }
        if (t == "double") {
            if (driver == "mysql") return "DOUBLE";
            return "REAL";
        }
        if (t == "decimal") {
            local p = this._precision != null ? this._precision : 8;
            local s = this._scale     != null ? this._scale     : 2;
            if (driver == "mysql") return "DECIMAL(" + p + ", " + s + ")";
            return "NUMERIC(" + p + ", " + s + ")";
        }

        // Boolean (stored as 0/1)
        if (t == "boolean") {
            if (driver == "mysql") return "TINYINT(1)";
            return "INTEGER";
        }

        // JSON (MySQL has a native JSON type; SQLite stores as TEXT)
        if (t == "json") {
            if (driver == "mysql") return "JSON";
            return "TEXT";
        }

        // Binary
        if (t == "binary" || t == "blob") return "BLOB";

        // Date/time — stored as strings in SQLite, native types in MySQL
        if (t == "date") {
            if (driver == "mysql") return "DATE";
            return "TEXT";
        }
        if (t == "dateTime") {
            if (driver == "mysql") return "DATETIME";
            return "TEXT";
        }
        if (t == "time") {
            if (driver == "mysql") return "TIME";
            return "TEXT";
        }

        // Timestamp stored as BIGINT (Unix ms) — matches new Date().getTime() in the ORM
        if (t == "timestamp") return "BIGINT";

        // Pass-through: caller supplied a raw SQL type string
        return t;
    }

    // ── Column fragment (no trailing comma) ──────────────────────────────────

    fn toSqlFragment(driver) {
        local sql = "`" + this._name + "` " + this._sqlType(driver);

        // id / bigId: emit AUTO INCREMENT + PRIMARY KEY and return early —
        // no further constraints are valid on a PK autoincrement column.
        if (this._type == "id" || this._type == "bigId") {
            if (driver == "mysql") {
                return sql + " AUTO_INCREMENT PRIMARY KEY";
            }
            return sql + " PRIMARY KEY AUTOINCREMENT";
        }

        if (!this._nullable) sql = sql + " NOT NULL";

        if (this._hasDefault) {
            if (this._defaultVal == null) {
                sql = sql + " DEFAULT NULL";
            } else if (this._defaultVal == true) {
                sql = sql + " DEFAULT 1";
            } else if (this._defaultVal == false) {
                sql = sql + " DEFAULT 0";
            } else {
                sql = sql + " DEFAULT '" + this._defaultVal + "'";
            }
        }

        if (this._unique)  sql = sql + " UNIQUE";
        if (this._primary) sql = sql + " PRIMARY KEY";
        if (this._autoInc) {
            if (driver == "mysql") {
                sql = sql + " AUTO_INCREMENT";
            } else {
                sql = sql + " AUTOINCREMENT";
            }
        }

        return sql;
    }

    // Returns a FOREIGN KEY fragment string, or null if no reference is set.
    // Emitted as a separate table-level constraint in Blueprint.toSql().
    fn toForeignFragment() {
        if (this._references == null) return null;
        return "FOREIGN KEY (`" + this._name + "`) REFERENCES `" +
               this._references.table + "` (`" + this._references.column + "`)";
    }
}

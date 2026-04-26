import { Blueprint   } from "./blueprint";
import { format, println, print, setColor } from "core:io";
import { byteLength  } from "core:string";
import { Object      } from "core:object";

// ─────────────────────────────────────────────────────────────────────────────
//  Migration
//  Base class for all migrations. Override up() and down() in your subclass.
//  The name() method returns the class name by default — override it to set a
//  custom stable identifier (used as the primary key in the migrations table).
//
//  Example:
//
//      import { Migration }      from "../core/migration";
//      import { SchemaBuilder }  from "../core/migration";
//
//      class CreateUsersTable (Migration) {
//          fn init() { base(this); }
//
//          fn up(schema) {
//              schema.create("users", fn(t) {
//                  t.id();
//                  t.string("name", 100);
//                  t.string("email", 191).unique();
//                  t.string("password", 255);
//                  t.boolean("is_admin").defaultVal(false);
//                  t.timestamps();
//                  t.softDeletes();
//              });
//          }
//
//          fn down(schema) {
//              schema.drop("users");
//          }
//      }
// ─────────────────────────────────────────────────────────────────────────────

class Migration {
    fn init() { }

    // Stable identifier — defaults to the class name.
    // Override if you rename the class to preserve the migration history.
    fn name() {
        return typeof(this);
    }

    // Called by MigrationRunner when running migrations.
    // Receives a SchemaBuilder — use schema.create(table, callback) to define tables.
    fn up(schema) { }

    // Called by MigrationRunner when rolling back.
    // Receives a SchemaBuilder — use schema.drop(table) to undo.
    fn down(schema) { }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SchemaBuilder
//  Thin wrapper over DbContext passed to Migration.up() / .down().
//  Provides create(table, callback) and drop(table) as the public DDL surface.
// ─────────────────────────────────────────────────────────────────────────────

class SchemaBuilder {
    fn init(db) {
        this._db     = db;
        this._driver = db._type;
    }

    // Creates a table. callback(blueprint) receives a Blueprint to define columns.
    fn create(table, callback) {
        local bp = new Blueprint(table, this._driver);
        callback(bp);
        this._db.exec(bp.toSql());
        local idxSqls = bp.toIndexSqls();
        local i       = 0;
        while (i < idxSqls.length()) {
            this._db.exec(idxSqls[i]);
            i = i + 1;
        }
    }

    // Drops a table (IF EXISTS — safe to call even if the table doesn't exist).
    fn drop(table) {
        this._db.exec("DROP TABLE IF EXISTS `" + table + "`");
    }

    // Renames a table.
    fn rename(oldName, newName) {
        this._db.exec("ALTER TABLE `" + oldName + "` RENAME TO `" + newName + "`");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  MigrationRunner
//  Executes an ordered list of Migration instances against a DbContext.
//
//  Tracks which migrations have been run in a `migrations` table (created
//  automatically). Each run groups migrations under an incrementing batch
//  number — rollback reverses the last batch (or N batches with steps).
//
//  Usage:
//      const runner = new MigrationRunner(DB);
//      await runner.migrate(DB._migrations);           // run pending
//      await runner.rollback(DB._migrations);          // undo last batch
//      await runner.rollback(DB._migrations, 2);       // undo last 2 batches
//      await runner.fresh(DB._migrations);             // drop all + re-run
//      await runner.status(DB._migrations);            // print status table
// ─────────────────────────────────────────────────────────────────────────────

class MigrationRunner {

    fn init(db) {
        this._db     = db;
        this._driver = db._type;
    }

    // ── Migrations tracking table ─────────────────────────────────────────────

    fn _ensureMigrationsTable() {
        local bp = new Blueprint("migrations", this._driver);
        bp.id("id");
        bp.string("migration", 255).unique();
        bp.integer("batch").notNull();
        this._db.exec(bp.toSql());
    }

    fn _getRanRows() async {
        return await this._db.select({
            table:       "migrations",
            selects:     ["*"],
            wheres:      [],
            orders:      [{ column: "batch", direction: "ASC" }],
            joins:       [],
            groups:      [],
            havings:     [],
            limit:       null,
            offset:      null,
            withTrashed: false
        });
    }

    fn _getLastBatch() async {
        local rows = await this._db.select({
            table:       "migrations",
            selects:     ["*"],
            wheres:      [],
            orders:      [{ column: "batch", direction: "DESC" }],
            joins:       [],
            groups:      [],
            havings:     [],
            limit:       1,
            offset:      null,
            withTrashed: false
        });
        if (rows.length() == 0) return 0;
        return rows[0].batch;
    }

    fn _recordMigration(name, batch) async {
        await this._db.insert({
            table: "migrations",
            data:  { migration: name, batch: batch }
        });
    }

    fn _removeMigration(name) async {
        await this._db.delete({
            table:  "migrations",
            wheres: [{ column: "migration", op: "=", value: name, boolean: "AND" }]
        });
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    // Pads a string on the right to `width` bytes (ASCII-safe).
    fn _pad(s, width) {
        local out = s;
        while (byteLength(out) < width) {
            out = out + " ";
        }
        return out;
    }

    fn _runUp(migration) {
        local schema = new SchemaBuilder(this._db);
        migration.up(schema);
    }

    fn _runDown(migration) {
        local schema = new SchemaBuilder(this._db);
        migration.down(schema);
    }

    fn _inArray(arr, val) {
        local i = 0;
        while (i < arr.length()) {
            if (arr[i] == val) return true;
            i = i + 1;
        }
        return false;
    }

    fn _findMigration(migrations, name) {
        local i = 0;
        while (i < migrations.length()) {
            if (migrations[i].name() == name) return migrations[i];
            i = i + 1;
        }
        return null;
    }

    // ── Public commands ───────────────────────────────────────────────────────

    // Run all pending migrations (those not yet recorded in the migrations table).
    fn migrate(migrations) async {
        this._ensureMigrationsTable();

        local ranRows = await this._getRanRows();
        local ran     = [];
        local i       = 0;
        while (i < ranRows.length()) {
            ran.push(ranRows[i].migration);
            i = i + 1;
        }

        local batch = (await this._getLastBatch()) + 1;
        local count = 0;

        local j = 0;
        while (j < migrations.length()) {
            local m     = migrations[j];
            local mName = m.name();

            if (!this._inArray(ran, mName)) {
                setColor(33); print("  Migrating:  "); setColor();
                println(mName);
                this._runUp(m);
                await this._recordMigration(mName, batch);
                setColor(32); print("  Migrated:   "); setColor();
                println(mName);
                count = count + 1;
            }
            j = j + 1;
        }

        if (count == 0) {
            println("  Nothing to migrate.");
        } else {
            println(format("\n  {} migration(s) ran successfully.", count));
        }
    }

    // Roll back the last N batches (default: 1).
    fn rollback(migrations, steps) async {
        this._ensureMigrationsTable();
        if (steps == null) steps = 1;

        // Fetch all ran migrations ordered batch DESC (most recent first)
        local rows = await this._db.select({
            table:       "migrations",
            selects:     ["*"],
            wheres:      [],
            orders:      [{ column: "batch", direction: "DESC" }],
            joins:       [],
            groups:      [],
            havings:     [],
            limit:       null,
            offset:      null,
            withTrashed: false
        });

        if (rows.length() == 0) {
            println("  Nothing to rollback.");
            return;
        }

        // Collect distinct batch numbers in DESC order
        local batchNums = [];
        local i         = 0;
        while (i < rows.length()) {
            local b = rows[i].batch;
            if (!this._inArray(batchNums, b)) batchNums.push(b);
            i = i + 1;
        }

        // Take only `steps` batches
        local targetBatches = [];
        local n = 0;
        while (n < batchNums.length() && n < steps) {
            targetBatches.push(batchNums[n]);
            n = n + 1;
        }

        // Collect migration names in those batches (already in DESC run order)
        local toRevert = [];
        local j        = 0;
        while (j < rows.length()) {
            if (this._inArray(targetBatches, rows[j].batch)) {
                toRevert.push(rows[j].migration);
            }
            j = j + 1;
        }

        local count = 0;
        local k     = 0;
        while (k < toRevert.length()) {
            local mName = toRevert[k];
            local mObj  = this._findMigration(migrations, mName);

            setColor(33); print("  Rolling back: "); setColor();
            println(mName);

            if (mObj != null) {
                this._runDown(mObj);
            } else {
                setColor(31);
                println("  Warning: migration class not found for '" + mName + "' — skipping down()");
                setColor();
            }

            await this._removeMigration(mName);
            setColor(32); print("  Rolled back:  "); setColor();
            println(mName);
            count = count + 1;
            k     = k + 1;
        }

        println(format("\n  {} migration(s) rolled back.", count));
    }

    // Drop every table tracked by the registered migrations (all down() methods
    // in reverse order), drop the migrations table itself, then re-run migrate().
    fn fresh(migrations) async {
        local schema = new SchemaBuilder(this._db);

        setColor(31); println("  Dropping all tables…"); setColor();

        local i = migrations.length() - 1;
        while (i >= 0) {
            migrations[i].down(schema);
            i = i - 1;
        }
        this._db.exec("DROP TABLE IF EXISTS `migrations`");
        setColor(32); println("  Done."); setColor();
        println();

        await this.migrate(migrations);
    }

    // Print the current status of every registered migration.
    fn status(migrations) async {
        this._ensureMigrationsTable();

        // Load all ran migrations in one query
        local ranRows = await this._getRanRows();
        local ranMap  = {};
        local i       = 0;
        while (i < ranRows.length()) {
            ranMap[ranRows[i].migration] = ranRows[i].batch;
            i = i + 1;
        }

        // Header
        println("+--" + this._pad("", 45) + "+-------+-----------+");
        println("| " + this._pad("Migration",  45) + "| Batch | Status    |");
        println("+--" + this._pad("", 45) + "+-------+-----------+");

        local j = 0;
        while (j < migrations.length()) {
            local mName  = migrations[j].name();
            local batch  = ranMap[mName];
            local isRan  = batch != null;
            local bStr   = isRan ? (batch + "") : "-";

            local nameCol  = this._pad(mName, 45);
            local batchCol = this._pad(bStr, 5);
            local statusCol;

            if (isRan) {
                setColor(32);
                statusCol = "Ran      ";
            } else {
                setColor(33);
                statusCol = "Pending  ";
            }

            print("| " + nameCol + "| " + batchCol + " | ");
            print(statusCol);
            setColor();
            println("|");
            j = j + 1;
        }

        println("+--" + this._pad("", 45) + "+-------+-----------+");
    }
}

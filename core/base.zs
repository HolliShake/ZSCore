
import { format, parseNum } from "core:io";
import { toLower }          from "core:string";
import { Object }           from "core:object";
import { Date }             from "core:date";
import { ceil }             from "core:math";
import { stringify, parse } from "core:json";

// ─────────────────────────────────────────────────────────────────────────────
//  QueryBuilder
//  Chainable, composable query builder returned by every static Model method.
//  All filter / sort / pagination calls return `this` so they can be chained.
//  Terminal calls (get, first, count, …) are async and return database results.
//
//  Example:
//      local active = await User.where("status", "active")
//                                .orderByDesc("created_at")
//                                .limit(10)
//                                .get();
// ─────────────────────────────────────────────────────────────────────────────

class QueryBuilder {

    fn init(modelClass, table, db) {
        this._modelClass  = modelClass;
        this._table       = table;
        this._db          = db;
        this._selects     = ["*"];
        this._wheres      = [];
        this._orders      = [];
        this._joins       = [];
        this._groups      = [];
        this._havings     = [];
        this._limitVal    = null;
        this._offsetVal   = null;
        this._withTrashed = false;
    }

    // ── Projection ────────────────────────────────────────────────────────────

    fn select(columns) {
        this._selects = columns;
        return this;
    }

    // ── Conditions ────────────────────────────────────────────────────────────

    fn _pushWhere(column, operatorOrValue, value, boolean) {
        local op  = "=";
        local val = operatorOrValue;
        if (value != null) {
            op  = operatorOrValue;
            val = value;
        }
        this._wheres.push({ column: column, op: op, value: val, boolean: boolean });
        return this;
    }

    fn where(column, operatorOrValue, value) {
        return this._pushWhere(column, operatorOrValue, value, "AND");
    }

    fn orWhere(column, operatorOrValue, value) {
        return this._pushWhere(column, operatorOrValue, value, "OR");
    }

    fn whereIn(column, values) {
        this._wheres.push({ column: column, op: "IN", value: values, boolean: "AND" });
        return this;
    }

    fn whereNotIn(column, values) {
        this._wheres.push({ column: column, op: "NOT IN", value: values, boolean: "AND" });
        return this;
    }

    fn whereNull(column) {
        this._wheres.push({ column: column, op: "IS NULL", value: null, boolean: "AND" });
        return this;
    }

    fn whereNotNull(column) {
        this._wheres.push({ column: column, op: "IS NOT NULL", value: null, boolean: "AND" });
        return this;
    }

    fn whereBetween(column, min, max) {
        this._wheres.push({ column: column, op: "BETWEEN", value: [min, max], boolean: "AND" });
        return this;
    }

    fn whereRaw(sql, bindings) {
        this._wheres.push({ raw: sql, bindings: bindings, boolean: "AND" });
        return this;
    }

    // ── Ordering ──────────────────────────────────────────────────────────────

    fn orderBy(column, direction) {
        if (direction == null) direction = "ASC";
        this._orders.push({ column: column, direction: direction });
        return this;
    }

    fn orderByDesc(column) {
        return this.orderBy(column, "DESC");
    }

    fn latest(column) {
        if (column == null) column = "created_at";
        return this.orderByDesc(column);
    }

    fn oldest(column) {
        if (column == null) column = "created_at";
        return this.orderBy(column, "ASC");
    }

    // ── Grouping ──────────────────────────────────────────────────────────────

    fn groupBy(column) {
        this._groups.push(column);
        return this;
    }

    fn having(column, operatorOrValue, value) {
        local op  = "=";
        local val = operatorOrValue;
        if (value != null) {
            op  = operatorOrValue;
            val = value;
        }
        this._havings.push({ column: column, op: op, value: val });
        return this;
    }

    // ── Pagination controls ───────────────────────────────────────────────────

    fn limit(n) {
        this._limitVal = n;
        return this;
    }

    fn take(n) {
        return this.limit(n);
    }

    fn offset(n) {
        this._offsetVal = n;
        return this;
    }

    fn skip(n) {
        return this.offset(n);
    }

    // ── Joins ─────────────────────────────────────────────────────────────────

    fn join(table, localKey, foreignKey) {
        this._joins.push({ type: "INNER JOIN", table: table, localKey: localKey, foreignKey: foreignKey });
        return this;
    }

    fn leftJoin(table, localKey, foreignKey) {
        this._joins.push({ type: "LEFT JOIN", table: table, localKey: localKey, foreignKey: foreignKey });
        return this;
    }

    fn rightJoin(table, localKey, foreignKey) {
        this._joins.push({ type: "RIGHT JOIN", table: table, localKey: localKey, foreignKey: foreignKey });
        return this;
    }

    // ── Soft-delete visibility ────────────────────────────────────────────────

    fn withTrashed() {
        this._withTrashed = true;
        return this;
    }

    fn onlyTrashed() {
        this._withTrashed = true;
        this._wheres.push({ column: "deleted_at", op: "IS NOT NULL", value: null, boolean: "AND" });
        return this;
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    fn _payload() {
        return {
            table:       this._table,
            selects:     this._selects,
            wheres:      this._wheres,
            orders:      this._orders,
            joins:       this._joins,
            groups:      this._groups,
            havings:     this._havings,
            limit:       this._limitVal,
            offset:      this._offsetVal,
            withTrashed: this._withTrashed
        };
    }

    fn _hydrate(rows) {
        // Returns plain DB row objects.
        // Single-record methods (first, find, findOrFail) hydrate the model
        // instance directly; multi-record results are plain attribute objects.
        return rows;
    }

    fn _pkCol() {
        return this._modelClass._primaryKey;
    }

    // ── Terminal operations ───────────────────────────────────────────────────

    fn get() async {
        local rows = await this._db.select(this._payload());
        return this._hydrate(rows);
    }

    fn first() async {
        this._limitVal = 1;
        local rows     = await this._db.select(this._payload());
        if (rows.length() == 0) return null;
        this._modelClass._rawFill(rows[0]);
        this._modelClass._exists = true;
        return this._modelClass;
    }

    fn firstOrFail() async {
        local result = await this.first();
        if (result == null) {
            raise format("ModelNotFoundError: no record in table '{}'", this._table);
        }
        return result;
    }

    fn find(id) async {
        return await this.where(this._pkCol(), id).first();
    }

    fn findOrFail(id) async {
        local result = await this.find(id);
        if (result == null) {
            raise format("ModelNotFoundError: id={} not found in '{}'", id, this._table);
        }
        return result;
    }

    fn count() async {
        local payload     = this._payload();
        payload.aggregate = "COUNT";
        local row         = await this._db.aggregate(payload);
        return row.result;
    }

    fn sum(column) async {
        local payload           = this._payload();
        payload.aggregate       = "SUM";
        payload.aggregateColumn = column;
        local row               = await this._db.aggregate(payload);
        return row.result;
    }

    fn avg(column) async {
        local payload           = this._payload();
        payload.aggregate       = "AVG";
        payload.aggregateColumn = column;
        local row               = await this._db.aggregate(payload);
        return row.result;
    }

    fn min(column) async {
        local payload           = this._payload();
        payload.aggregate       = "MIN";
        payload.aggregateColumn = column;
        local row               = await this._db.aggregate(payload);
        return row.result;
    }

    fn max(column) async {
        local payload           = this._payload();
        payload.aggregate       = "MAX";
        payload.aggregateColumn = column;
        local row               = await this._db.aggregate(payload);
        return row.result;
    }

    fn exists() async {
        return (await this.count()) > 0;
    }

    fn doesntExist() async {
        return (await this.count()) == 0;
    }

    fn paginate(page, perPage) async {
        if (page    == null) page    = 1;
        if (perPage == null) perPage = 15;
        local total     = await this.count();
        this._limitVal  = perPage;
        this._offsetVal = (page - 1) * perPage;
        local data      = await this.get();
        return {
            data:         data,
            total:        total,
            per_page:     perPage,
            current_page: page,
            last_page:    ceil(total / perPage),
            range_from:   this._offsetVal + 1,
            range_to:     this._offsetVal + data.length()
        };
    }

    fn simplePaginate(page, perPage) async {
        if (page    == null) page    = 1;
        if (perPage == null) perPage = 15;
        // fetch one extra to detect whether a next page exists
        this._limitVal  = perPage + 1;
        this._offsetVal = (page - 1) * perPage;
        local rows      = await this._db.select(this._payload());
        local hasMore   = rows.length() > perPage;
        if (hasMore) rows.pop();
        return {
            data:         this._hydrate(rows),
            per_page:     perPage,
            current_page: page,
            has_more:     hasMore
        };
    }

    fn pluck(column) async {
        local rows   = await this._db.select(this._payload());
        local values = [];
        local i      = 0;
        while (i < rows.length()) {
            values.push(rows[i][column]);
            i = i + 1;
        }
        return values;
    }

    fn chunk(size, callback) async {
        local page = 1;
        local stop = false;
        while (!stop) {
            local batch = await this.paginate(page, size);
            if (batch.data.length() == 0) {
                stop = true;
            } else {
                await callback(batch.data);
                if (batch.data.length() < size) { stop = true; }
                else { page = page + 1; }
            }
        }
    }

    fn update(data) async {
        return await this._db.update({
            table:  this._table,
            data:   data,
            wheres: this._wheres
        });
    }

    fn delete() async {
        return await this._db.delete({
            table:  this._table,
            wheres: this._wheres
        });
    }

    fn increment(column, amount) async {
        if (amount == null) amount = 1;
        return await this._db.increment({
            table:  this._table,
            column: column,
            amount: amount,
            wheres: this._wheres
        });
    }

    fn decrement(column, amount) async {
        if (amount == null) amount = 1;
        return await this._db.increment({
            table:  this._table,
            column: column,
            amount: 0 - amount,
            wheres: this._wheres
        });
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Model
//  Base class for all domain models.  Extend and configure _table, _fillable,
//  etc. in your subclass init(), then call base(this) first.
//
//  Quick-start
//  ───────────
//      class User (Model) {
//          fn init() {
//              base(this);
//              this._table       = "users";
//              this._fillable    = ["name", "email", "password"];
//              this._hidden      = ["password"];
//              this._timestamps  = true;
//              this._softDeletes = true;
//              this._casts       = { is_admin: "bool", settings: "json" };
//          }
//      }
//
//      // ── Read ──
//      local user  = await User.findOrFail(1);
//      local list  = await User.where("is_admin", true).orderBy("name").get();
//      local page  = await User.latest().paginate(1, 20);
//
//      // ── Write ──
//      local user  = await User.create({ name: "Alice", email: "a@b.com" });
//      await user.update({ name: "Alice Smith" });
//      await user.delete();          // soft-delete if enabled
//      await user.restore();         // undo soft-delete
//      await user.forceDelete();     // permanent remove
//
//      // ── Relationships ──
//      local posts   = await user.hasMany(Post, "user_id");
//      local profile = await user.hasOne(Profile, "user_id");
//      local company = await user.belongsTo(Company, "company_id");
//      local roles   = await user.belongsToMany(Role, "user_roles", "user_id", "role_id");
// ─────────────────────────────────────────────────────────────────────────────

class Model {

    static _connection = null;

    fn init() {
        // ── Schema config (override in subclass) ───────────────────────────
        this._table       = toLower(typeof(this));  // e.g. "User" → "user"; override to "users"
        this._primaryKey  = "id";
        this._fillable    = [];                    // empty list = all non-guarded allowed
        this._guarded     = ["id", "created_at", "updated_at", "deleted_at"];
        this._hidden      = [];                    // stripped from toObject / toJSON
        this._casts       = {};                    // col → "int"|"float"|"bool"|"json"|"date"
        this._timestamps  = true;
        this._softDeletes = false;

        // ── Internal state ─────────────────────────────────────────────────
        this._attributes  = {};
        this._original    = {};
        this._dirty       = {};
        this._exists      = false;
        this._relations   = {};

        // ── DB connection (bootstrap once via Model.setDB(conn)) ───────────
        this._db          = Model._connection;
    }

    // ── Global DB connection ──────────────────────────────────────────────────

    static fn setDB(connection) {
        Model._connection = connection;
    }

    static fn getDB() {
        return Model._connection;
    }

    // ── Query factory ─────────────────────────────────────────────────────────
    //  ZScript static methods do not expose `this`, so all query shortcuts are
    //  instance methods. Usage: new User().where(...).get()

    fn query() {
        return new QueryBuilder(this, this._table, this._db);
    }

    // ── Query shortcuts (proxy to QueryBuilder) ───────────────────────────────

    fn all() async {
        return await this.query().get();
    }

    fn find(id) async {
        return await this.query().find(id);
    }

    fn findOrFail(id) async {
        return await this.query().findOrFail(id);
    }

    fn findMany(ids) async {
        return await this.query().whereIn(this._primaryKey, ids).get();
    }

    fn where(column, operatorOrValue, value) {
        return this.query().where(column, operatorOrValue, value);
    }

    fn orWhere(column, operatorOrValue, value) {
        return this.query().orWhere(column, operatorOrValue, value);
    }

    fn whereIn(column, values) {
        return this.query().whereIn(column, values);
    }

    fn whereNull(column) {
        return this.query().whereNull(column);
    }

    fn whereNotNull(column) {
        return this.query().whereNotNull(column);
    }

    fn orderBy(column, direction) {
        return this.query().orderBy(column, direction);
    }

    fn orderByDesc(column) {
        return this.query().orderByDesc(column);
    }

    fn latest(column) {
        return this.query().latest(column);
    }

    fn oldest(column) {
        return this.query().oldest(column);
    }

    fn limit(n) {
        return this.query().limit(n);
    }

    fn skip(n) {
        return this.query().skip(n);
    }

    fn count() async {
        return await this.query().count();
    }

    fn paginate(page, perPage) async {
        return await this.query().paginate(page, perPage);
    }

    fn withTrashed() {
        return this.query().withTrashed();
    }

    fn onlyTrashed() {
        return this.query().onlyTrashed();
    }

    // ── Factory / upsert helpers ──────────────────────────────────────────────

    fn create(data) async {
        this.fill(data);
        await this.save();
        return this;
    }

    fn firstOrCreate(searchAttrs, extraAttrs) async {
        local qb   = this.query();
        local keys = Object.keys(searchAttrs);
        local i    = 0;
        while (i < keys.length()) {
            qb.where(keys[i], searchAttrs[keys[i]]);
            i = i + 1;
        }
        local found = await qb.first();
        if (found != null) return found;
        if (extraAttrs == null) extraAttrs = {};
        local merged = { ...searchAttrs, ...extraAttrs };
        this.fill(merged);
        await this.save();
        return this;
    }

    fn updateOrCreate(searchAttrs, updateAttrs) async {
        local qb   = this.query();
        local keys = Object.keys(searchAttrs);
        local i    = 0;
        while (i < keys.length()) {
            qb.where(keys[i], searchAttrs[keys[i]]);
            i = i + 1;
        }
        local found = await qb.first();
        if (found != null) {
            await found.update(updateAttrs);
            return found;
        }
        if (updateAttrs == null) updateAttrs = {};
        local merged = { ...searchAttrs, ...updateAttrs };
        this.fill(merged);
        await this.save();
        return this;
    }

    // ── Fillable / guarded guard ──────────────────────────────────────────────

    fn _isFillable(key) {
        local g = 0;
        while (g < this._guarded.length()) {
            if (this._guarded[g] == key) return false;
            g = g + 1;
        }
        if (this._fillable.length() == 0) return true;
        local f = 0;
        while (f < this._fillable.length()) {
            if (this._fillable[f] == key) return true;
            f = f + 1;
        }
        return false;
    }

    fn fill(data) {
        local keys = Object.keys(data);
        local i    = 0;
        while (i < keys.length()) {
            local key = keys[i];
            if (this._isFillable(key)) {
                this._attributes[key] = this._castSet(key, data[key]);
                this._dirty[key]      = true;
            }
            i = i + 1;
        }
        return this;
    }

    // Bypasses fillable check — used when hydrating rows from the DB
    fn _rawFill(data) {
        local keys = Object.keys(data);
        local i    = 0;
        while (i < keys.length()) {
            this._attributes[keys[i]] = data[keys[i]];
            i = i + 1;
        }
        this._original = { ...this._attributes };
        this._dirty    = {};
    }

    // ── Attribute access ──────────────────────────────────────────────────────

    fn getAttribute(key) {
        return this._castGet(key, this._attributes[key]);
    }

    fn setAttribute(key, value) {
        this._attributes[key] = this._castSet(key, value);
        this._dirty[key]      = true;
        return this;
    }

    // ── Type casting ──────────────────────────────────────────────────────────

    fn _castGet(key, value) {
        local cast = this._casts[key];
        if (cast == null)    return value;
        if (cast == "int")   return parseNum(value + "");
        if (cast == "float") return parseNum(value + "");
        if (cast == "bool")  return value == true || value == 1 || value == "true";
        if (cast == "json")  return parse(value);
        if (cast == "date")  return new Date(value);
        return value;
    }

    fn _castSet(key, value) {
        local cast = this._casts[key];
        if (cast == null)   return value;
        if (cast == "json") return stringify(value);
        if (cast == "date") return value + "";  // coerce to string for DB storage
        return value;
    }

    // ── Dirty / change tracking ───────────────────────────────────────────────

    fn isDirty() {
        return Object.keys(this._dirty).length() > 0;
    }

    fn isClean() {
        return !this.isDirty();
    }

    fn getDirty() {
        local out  = {};
        local keys = Object.keys(this._dirty);
        local i    = 0;
        while (i < keys.length()) {
            out[keys[i]] = this._attributes[keys[i]];
            i = i + 1;
        }
        return out;
    }

    fn wasChanged(key) {
        if (key == null) return this.isDirty();
        return this._dirty[key] == true;
    }

    // ── Persistence ───────────────────────────────────────────────────────────

    fn save() async {
        await this._fireEvent("saving");

        if (this._timestamps) {
            local now = new Date().getTime();
            if (!this._exists) this._attributes["created_at"] = now;
            this._attributes["updated_at"] = now;
        }

        if (this._exists) {
            await this._fireEvent("updating");
            await this._performUpdate();
            await this._fireEvent("updated");
        } else {
            await this._fireEvent("creating");
            await this._performInsert();
            await this._fireEvent("created");
        }

        this._original = { ...this._attributes };
        this._dirty    = {};
        await this._fireEvent("saved");
        return this;
    }

    fn _performInsert() async {
        local result = await this._db.insert({
            table: this._table,
            data:  this._attributes
        });
        this._attributes[this._primaryKey] = result.insertId;
        this._exists = true;
        return result;
    }

    fn _performUpdate() async {
        local pk = this._primaryKey;
        return await this._db.update({
            table:  this._table,
            data:   this._attributes,
            wheres: [{ column: pk, op: "=", value: this._attributes[pk], boolean: "AND" }]
        });
    }

    fn update(data) async {
        this.fill(data);
        return await this.save();
    }

    fn delete() async {
        if (!this._exists) return false;
        await this._fireEvent("deleting");
        if (this._softDeletes) {
            this._attributes["deleted_at"] = new Date().getTime();
            await this._performUpdate();
        } else {
            local pk = this._primaryKey;
            await this._db.delete({
                table:  this._table,
                wheres: [{ column: pk, op: "=", value: this._attributes[pk], boolean: "AND" }]
            });
            this._exists = false;
        }
        await this._fireEvent("deleted");
        return true;
    }

    fn restore() async {
        if (!this._softDeletes) return false;
        this._attributes["deleted_at"] = null;
        await this.save();
        return true;
    }

    fn forceDelete() async {
        if (!this._exists) return false;
        local pk = this._primaryKey;
        await this._db.delete({
            table:  this._table,
            wheres: [{ column: pk, op: "=", value: this._attributes[pk], boolean: "AND" }]
        });
        this._exists = false;
        return true;
    }

    fn refresh() async {
        local pk   = this._primaryKey;
        local rows = await this._db.select({
            table:       this._table,
            selects:     ["*"],
            wheres:      [{ column: pk, op: "=", value: this._attributes[pk], boolean: "AND" }],
            orders:      [],
            joins:       [],
            groups:      [],
            havings:     [],
            limit:       1,
            offset:      null,
            withTrashed: true
        });
        if (rows.length() > 0) this._rawFill(rows[0]);
        return this;
    }

    // replicate() returns a plain attribute object (without PK and excluded keys).
    // Assign it to a fresh model instance to persist: new User()._rawFill(user.replicate())
    fn replicate(except) {
        if (except == null) except = [];
        local keys = Object.keys(this._attributes);
        local data = {};
        local i    = 0;
        while (i < keys.length()) {
            local key  = keys[i];
            local skip = key == this._primaryKey;
            local j    = 0;
            while (j < except.length()) {
                if (except[j] == key) { skip = true; }
                j = j + 1;
            }
            if (!skip) data[key] = this._attributes[key];
            i = i + 1;
        }
        return data;
    }

    // ── Lifecycle hooks ───────────────────────────────────────────────────────
    //  Override any of these in your subclass to react to persistence events.
    //  They run in order: saving → creating/updating → created/updated → saved

    fn _fireEvent(event) async {
        if (event == "saving")   { await this.onSaving();   }
        if (event == "creating") { await this.onCreating(); }
        if (event == "created")  { await this.onCreated();  }
        if (event == "updating") { await this.onUpdating(); }
        if (event == "updated")  { await this.onUpdated();  }
        if (event == "deleting") { await this.onDeleting(); }
        if (event == "deleted")  { await this.onDeleted();  }
        if (event == "saved")    { await this.onSaved();    }
    }

    fn onSaving()   async { }
    fn onCreating() async { }
    fn onCreated()  async { }
    fn onUpdating() async { }
    fn onUpdated()  async { }
    fn onDeleting() async { }
    fn onDeleted()  async { }
    fn onSaved()    async { }

    // ── Relationships ─────────────────────────────────────────────────────────

    // this model owns one row in `relatedClass` (e.g. User → Profile)
    fn hasOne(relatedClass, foreignKey, localKey) async {
        if (localKey == null) localKey = this._primaryKey;
        local id = this._attributes[localKey];
        return await relatedClass.query().where(foreignKey, id).first();
    }

    // this model owns many rows in `relatedClass` (e.g. User → Posts)
    fn hasMany(relatedClass, foreignKey, localKey) async {
        if (localKey == null) localKey = this._primaryKey;
        local id = this._attributes[localKey];
        return await relatedClass.query().where(foreignKey, id).get();
    }

    // this model holds the foreign key (e.g. Post → User via post.user_id)
    fn belongsTo(relatedClass, foreignKey, ownerKey) async {
        if (ownerKey == null) ownerKey = "id";
        local fkVal = this._attributes[foreignKey];
        return await relatedClass.query().where(ownerKey, fkVal).first();
    }

    // many-to-many via a pivot table (e.g. User ↔ Role via user_roles)
    fn belongsToMany(relatedClass, pivotTable, localFk, relatedFk) async {
        local myId     = this._attributes[this._primaryKey];
        local relInst  = new relatedClass();
        local relTable = relInst._table;
        local rows     = await this._db.select({
            table:       relTable,
            selects:     [format("{}.{}", relTable, "*")],
            joins:       [{
                type:       "INNER JOIN",
                table:      pivotTable,
                localKey:   format("{}.id", relTable),
                foreignKey: format("{}.{}", pivotTable, relatedFk)
            }],
            wheres:      [{ column: format("{}.{}", pivotTable, localFk), op: "=", value: myId, boolean: "AND" }],
            orders:      [],
            groups:      [],
            havings:     [],
            limit:       null,
            offset:      null,
            withTrashed: false
        });
        local qb = new QueryBuilder(relatedClass, relTable, this._db);
        return qb._hydrate(rows);
    }

    // polymorphic one-to-one (this model is the owner)
    fn morphOne(relatedClass, typeColumn, idColumn) async {
        local myType = typeof(this);
        local myId   = this._attributes[this._primaryKey];
        return await relatedClass.query()
            .where(typeColumn, myType)
            .where(idColumn, myId)
            .first();
    }

    // polymorphic one-to-many (this model is the owner)
    fn morphMany(relatedClass, typeColumn, idColumn) async {
        local myType = typeof(this);
        local myId   = this._attributes[this._primaryKey];
        return await relatedClass.query()
            .where(typeColumn, myType)
            .where(idColumn, myId)
            .get();
    }

    // polymorphic inverse — resolve the parent using a { TypeName: Class } map
    fn morphTo(typeColumn, idColumn, classMap) async {
        local type   = this._attributes[typeColumn];
        local id     = this._attributes[idColumn];
        local relCls = classMap[type];
        if (relCls == null) return null;
        return await relCls.find(id);
    }

    // ── Serialization ─────────────────────────────────────────────────────────

    fn toObject() {
        local out = { ...this._attributes };

        // apply read-side casts
        local ckeys = Object.keys(this._casts);
        local c     = 0;
        while (c < ckeys.length()) {
            local ck = ckeys[c];
            out[ck]  = this._castGet(ck, out[ck]);
            c = c + 1;
        }

        // include any eagerly loaded relation data
        local rkeys = Object.keys(this._relations);
        local r     = 0;
        while (r < rkeys.length()) {
            local rk = rkeys[r];
            out[rk]  = this._relations[rk];
            r = r + 1;
        }

        // nil-out hidden fields instead of deleting (safer with unknown runtimes)
        local h = 0;
        while (h < this._hidden.length()) {
            out[this._hidden[h]] = null;
            h = h + 1;
        }

        return out;
    }

    fn toJSON() {
        return stringify(this.toObject());
    }
}


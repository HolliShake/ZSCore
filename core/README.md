# ZScript ORM — `Model` & `QueryBuilder`

A full-featured, Eloquent-inspired ORM for ZScript. Supports chainable queries, relationships, soft deletes, lifecycle hooks, type casting, and pagination — all async-first.

---

## Table of Contents

1. [Setup](#1-setup)
2. [Defining a Model](#2-defining-a-model)
3. [Configuration Reference](#3-configuration-reference)
4. [Querying](#4-querying)
   - [Fetch all records](#fetch-all-records)
   - [Find by primary key](#find-by-primary-key)
   - [Filtering with `where`](#filtering-with-where)
   - [Ordering](#ordering)
   - [Grouping & Having](#grouping--having)
   - [Joins](#joins)
   - [Column projection](#column-projection)
   - [Limiting & offsetting](#limiting--offsetting)
5. [Aggregates](#5-aggregates)
6. [Pagination](#6-pagination)
7. [Creating & Saving Records](#7-creating--saving-records)
8. [Updating Records](#8-updating-records)
9. [Deleting Records](#9-deleting-records)
10. [Soft Deletes](#10-soft-deletes)
11. [Type Casting](#11-type-casting)
12. [Dirty / Change Tracking](#12-dirty--change-tracking)
13. [Lifecycle Hooks](#13-lifecycle-hooks)
14. [Relationships](#14-relationships)
    - [hasOne](#hasone)
    - [hasMany](#hasmany)
    - [belongsTo](#belongsto)
    - [belongsToMany (pivot)](#belongstomany-pivot)
    - [Polymorphic: morphOne / morphMany / morphTo](#polymorphic-morphone--morphmany--morphto)
15. [Bulk Operations](#15-bulk-operations)
16. [Serialization](#16-serialization)
17. [QueryBuilder API Reference](#17-querybuilder-api-reference)
18. [DbContext](#18-dbcontext)
    - [SQLite](#sqlite)
    - [MySQL / MariaDB](#mysql--mariadb)
    - [Subclassing DbContext](#subclassing-dbcontext)
    - [Raw DDL](#raw-ddl)
    - [Transactions](#transactions)
19. [Migrations](#19-migrations)
    - [Defining a migration](#defining-a-migration)
    - [Registering migrations](#registering-migrations)
    - [Running from the CLI](#running-from-the-cli)
    - [Blueprint column types](#blueprint-column-types)
    - [Column modifiers](#column-modifiers)
    - [Blueprint constraint helpers](#blueprint-constraint-helpers)
    - [MigrationRunner API](#migrationrunner-api)
20. [HTTP Server — ZServer](#20-http-server--zserver)
    - [Quick start](#quick-start)
    - [Routing](#routing)
    - [Controller routing](#controller-routing)
    - [Middleware](#middleware)
    - [ZServer API reference](#zserver-api-reference)
21. [Controller](#21-controller)

---

## 1. Setup

Import `Model` into your entry point and provide a database connection **once** before using any model.

```js
import { DB }    from "core:database";
import { Model } from "./model/base";

// Pass your database driver. Model stores it statically — all subclasses share it.
Model.setDB(DB);
```

`DB` must expose the following async methods (your database adapter):

| Method | Signature | Purpose |
|--------|-----------|---------|
| `select` | `(payload) → rows[]` | Run a SELECT |
| `insert` | `({ table, data }) → { insertId }` | Run an INSERT |
| `update` | `({ table, data, wheres }) → result` | Run an UPDATE |
| `delete` | `({ table, wheres }) → result` | Run a DELETE |
| `aggregate` | `(payload) → { result }` | Run COUNT / SUM / AVG / MIN / MAX |
| `increment` | `({ table, column, amount, wheres }) → result` | Atomic increment/decrement |

---

## 2. Defining a Model

Extend `Model`, call `base(this)` first, then override any defaults you need.

```js
import { Model } from "./model/base";

class User (Model) {
    fn init() {
        base(this);

        this._table       = "users";
        this._primaryKey  = "id";
        this._fillable    = ["name", "email", "password", "role"];
        this._hidden      = ["password"];
        this._timestamps  = true;
        this._softDeletes = true;
        this._casts       = {
            is_admin:  "bool",
            settings:  "json",
            born_at:   "date",
            score:     "float"
        };
    }
}
```

```js
class Post (Model) {
    fn init() {
        base(this);
        this._table    = "posts";
        this._fillable = ["title", "body", "user_id", "published"];
        this._casts    = { published: "bool" };
    }
}
```

---

## 3. Configuration Reference

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `_table` | `string` | lowercased class name | Database table name |
| `_primaryKey` | `string` | `"id"` | Primary key column |
| `_fillable` | `string[]` | `[]` (all allowed) | Columns allowed via `fill()` / `create()` |
| `_guarded` | `string[]` | `["id","created_at","updated_at","deleted_at"]` | Columns always blocked from mass-assignment |
| `_hidden` | `string[]` | `[]` | Columns stripped in `toObject()` / `toJSON()` |
| `_casts` | `object` | `{}` | Column → type map (`"int"`, `"float"`, `"bool"`, `"json"`, `"date"`) |
| `_timestamps` | `bool` | `true` | Auto-manage `created_at` / `updated_at` |
| `_softDeletes` | `bool` | `false` | `delete()` sets `deleted_at` instead of removing the row |

---

## 4. Querying

Every static query method returns a `QueryBuilder` that you can keep chaining. Call a **terminal method** (`get`, `first`, `count`, etc.) to execute the query.

### Fetch all records

```js
local users = await new User().all();
```

### Find by primary key

```js
local user = await new User().find(1);          // returns null if not found
local user = await new User().findOrFail(1);    // throws if not found
local users = await new User().findMany([1, 2, 3]);
```

### Filtering with `where`

**Shorthand (equality)**
```js
local admins = await new User().where("is_admin", true).get();
```

**Explicit operator**
```js
local seniors = await new User().where("age", ">=", 60).get();
local rich    = await new User().where("balance", ">", 10000).get();
```

**Supported operators:** `=`, `!=`, `<>`, `<`, `>`, `<=`, `>=`, `LIKE`, `NOT LIKE`

**Chaining multiple conditions (AND)**
```js
local result = await User
    .where("status", "active")
    .where("role", "editor")
    .get();
```

**OR condition**
```js
local result = await User
    .where("role", "admin")
    .orWhere("role", "superadmin")
    .get();
```

**IN / NOT IN**
```js
local result = await new User().whereIn("role", ["admin", "editor"]).get();
local result = await new User().whereNotIn("status", ["banned", "suspended"]).get();
```

**NULL checks**
```js
local unverified = await new User().whereNull("email_verified_at").get();
local verified   = await new User().whereNotNull("email_verified_at").get();
```

**Between**
```js
local midRange = await new User().query()
    .whereBetween("score", 50, 100)
    .get();
```

**Raw SQL fragment**
```js
local result = await new User().query()
    .whereRaw("LOWER(email) = ?", ["alice@example.com"])
    .get();
```

### Ordering

```js
local newest = await Post.orderByDesc("created_at").get();
local oldest = await Post.orderBy("created_at", "ASC").get();

// Shortcuts
local latest = await Post.latest().get();          // DESC created_at
local oldest = await Post.oldest().get();          // ASC  created_at
local byName = await new User().orderBy("name").get();   // ASC by default
```

### Grouping & Having

```js
local stats = await Post.query()
    .select(["user_id"])
    .groupBy("user_id")
    .having("COUNT(*)", ">", 5)
    .get();
```

### Joins

```js
local postsWithAuthors = await Post.query()
    .join("users", "posts.user_id", "users.id")
    .select(["posts.*", "users.name"])
    .get();

local result = await Post.query()
    .leftJoin("comments", "posts.id", "comments.post_id")
    .get();
```

### Column projection

```js
local emails = await new User().query()
    .select(["id", "email"])
    .get();
```

### Limiting & offsetting

```js
local top5 = await new User().limit(5).get();

local page2 = await new User().query()
    .limit(10)
    .skip(10)     // or .offset(10)
    .get();
```

---

## 5. Aggregates

```js
local total    = await new User().count();
local avgScore = await new User().query().avg("score");
local maxScore = await new User().query().max("score");
local minScore = await new User().query().min("score");
local sumBal   = await new User().query().sum("balance");

// Boolean checks
local hasAdmins = await new User().where("role", "admin").exists();
local noGuests  = await new User().where("role", "guest").doesntExist();
```

---

## 6. Pagination

### Full pagination (includes total count)

```js
local page = await new User().latest().paginate(1, 15);

// page shape:
// {
//   data:         User[],
//   total:        number,   ← total matching rows
//   per_page:     15,
//   current_page: 1,
//   last_page:    number,
//   from:         1,
//   to:           15
// }
```

### Simple pagination (no total — faster for large tables)

```js
local page = await new User().latest().simplePaginate(2, 20);

// page shape:
// {
//   data:         User[],
//   per_page:     20,
//   current_page: 2,
//   has_more:     bool
// }
```

---

## 7. Creating & Saving Records

### `Model.create(data)` — mass-assign and persist in one step

```js
local user = await new User().create({
    name:     "Alice",
    email:    "alice@example.com",
    password: "hashed_secret",
    role:     "editor"
});

// user._exists == true, user.getAttribute("id") is populated
```

### `new` + `fill` + `save` — manual flow

```js
local user = new User();
user.fill({ name: "Bob", email: "bob@example.com" });
await user.save();
```

### `firstOrCreate` — find or insert

```js
// Searches by the first map, creates with merged maps if not found
local user = await new User().firstOrCreate(
    { email: "carol@example.com" },
    { name: "Carol", role: "viewer" }
);
```

### `updateOrCreate` — upsert

```js
local user = await new User().updateOrCreate(
    { email: "carol@example.com" },       // search keys
    { name: "Carol Updated", role: "admin" } // apply these on create or update
);
```

---

## 8. Updating Records

### Instance update

```js
local user = await new User().findOrFail(1);
await user.update({ name: "Dave", role: "admin" });
```

### `setAttribute` + `save`

```js
user.setAttribute("name", "Eve");
user.setAttribute("role", "editor");
await user.save();
```

### Bulk update via QueryBuilder

```js
// Updates every matching row directly — no model instances are hydrated
await new User().where("status", "pending").update({ status: "active" });
```

---

## 9. Deleting Records

### Instance delete

```js
local user = await new User().findOrFail(5);
await user.delete();
// If _softDeletes = true  → sets deleted_at timestamp
// If _softDeletes = false → removes the row permanently
```

### Bulk delete via QueryBuilder

```js
await new User().where("status", "banned").delete();
```

### Force delete (bypass soft delete)

```js
await user.forceDelete();   // always removes the row
```

---

## 10. Soft Deletes

Enable on your model:

```js
this._softDeletes = true;
```

By default, all queries **exclude** soft-deleted rows. Use the following to include or isolate them:

```js
// Include soft-deleted rows alongside normal rows
local all = await new User().withTrashed().get();

// Only soft-deleted rows
local trashed = await new User().onlyTrashed().get();

// Restore a soft-deleted record
local user = await new User().withTrashed().find(7);
await user.restore();

// Permanently delete a soft-deleted record
await user.forceDelete();
```

The `deleted_at` column must exist on the table. When `_timestamps` is also `true`, `created_at` and `updated_at` are managed automatically.

---

## 11. Type Casting

Declare casts in `_casts`. Values are automatically cast on read (`getAttribute`, `toObject`) and coerced on write (`fill`, `setAttribute`).

```js
this._casts = {
    is_admin:  "bool",     // stored as 0/1, read as true/false
    score:     "float",    // stored as text, read as Float
    age:       "int",      // stored as text, read as Int
    settings:  "json",     // stored as JSON string, read as object
    born_at:   "date"      // stored as date string, read as Date object
};
```

| Cast token | Write (store) | Read (retrieve) |
|------------|---------------|-----------------|
| `"int"` | as-is | `parseNum(value + "")` |
| `"float"` | as-is | `parseNum(value + "")` |
| `"bool"` | as-is | `true` if `true`, `1`, or `"true"` |
| `"json"` | `stringify(value)` | `parse(value)` |
| `"date"` | `value + ""` (string coerce) | `new Date(value)` |

---

## 12. Dirty / Change Tracking

The ORM tracks which attributes have changed since the record was last loaded or saved.

```js
local user = await new User().find(1);

user.setAttribute("name", "Frank");

user.isDirty();          // true
user.isClean();          // false
user.wasChanged("name"); // true
user.wasChanged("email");// false
user.getDirty();         // { name: "Frank" }

await user.save();

user.isDirty();          // false — cleared after save
```

---

## 13. Lifecycle Hooks

Override any hook method in your subclass. They are called automatically during `save()` and `delete()` and are all `async`.

```js
class User (Model) {
    fn init() {
        base(this);
        this._table    = "users";
        this._fillable = ["name", "email", "password"];
    }

    fn onCreating() async {
        // Hash the password before the row is inserted
        this._attributes["password"] = await hashPassword(this._attributes["password"]);
    }

    fn onCreated() async {
        // Send a welcome email after the row is successfully inserted
        await sendWelcomeEmail(this._attributes["email"]);
    }

    fn onDeleting() async {
        // Clean up related records before deletion
        await Post.where("user_id", this.getAttribute("id")).delete();
    }
}
```

| Hook | When it fires |
|------|--------------|
| `onSaving` | Before any save (insert or update) |
| `onCreating` | Before INSERT |
| `onCreated` | After INSERT |
| `onUpdating` | Before UPDATE |
| `onUpdated` | After UPDATE |
| `onDeleting` | Before DELETE / soft-delete |
| `onDeleted` | After DELETE / soft-delete |
| `onSaved` | After any save (insert or update) |

---

## 14. Relationships

All relationship methods are `async` and return model instances (or arrays of instances).

### `hasOne`

The related model contains the foreign key pointing back to this model.

```js
class User (Model) { ... }
class Profile (Model) { ... }

// Profile table has a `user_id` column
local profile = await user.hasOne(Profile, "user_id");
```

### `hasMany`

```js
class Post (Model) { ... }

local posts = await user.hasMany(Post, "user_id");

// Optional: use a custom local key
local posts = await user.hasMany(Post, "user_id", "id");
```

### `belongsTo`

This model holds the foreign key (inverse of `hasOne` / `hasMany`).

```js
class Post (Model) { ... }
class User (Model) { ... }

// Post has a `user_id` column
local author = await post.belongsTo(User, "user_id");

// Optional: custom owner key
local author = await post.belongsTo(User, "user_id", "id");
```

### `belongsToMany` (pivot)

Many-to-many through an intermediate pivot table.

```js
class User (Model) { ... }
class Role (Model) { ... }

// Pivot table: user_roles (user_id, role_id)
local roles = await user.belongsToMany(Role, "user_roles", "user_id", "role_id");
```

### Polymorphic: `morphOne` / `morphMany` / `morphTo`

Useful when multiple model types share the same related table (e.g., comments on both posts and videos).

```js
// comments table: { id, body, commentable_type, commentable_id }

// On Post:
local comments = await post.morphMany(Comment, "commentable_type", "commentable_id");

// On Comment:
local parent = await comment.morphTo("commentable_type", "commentable_id", {
    Post:  Post,
    Video: Video
});
```

---

## 15. Bulk Operations

### `pluck` — extract a single column as a flat array

```js
local emails = await new User().where("status", "active").pluck("email");
// ["alice@example.com", "bob@example.com", ...]
```

### `chunk` — process large datasets in batches

```js
await new User().oldest().chunk(100, fn(batch) async {
    local i = 0;
    while (i < batch.length) {
        await processUser(batch[i]);
        i = i + 1;
    }
});
```

### `increment` / `decrement`

```js
await new User().where("id", 1).increment("login_count");
await new User().where("id", 1).increment("score", 10);
await Product.where("id", 5).decrement("stock", 2);
```

### `replicate` — clone a record without persisting

```js
local template = await Post.findOrFail(1);
local draft    = template.replicate(["created_at", "updated_at"]);
draft.setAttribute("title", "Copy of " + template.getAttribute("title"));
await draft.save();
```

### `refresh` — reload from the database

```js
await user.refresh();   // re-fetches all attributes from the DB
```

---

## 16. Serialization

### `toObject()` — returns a plain object

- Applies read-side type casts
- Includes eagerly cached relation data (stored in `_relations`)
- Nulls out `_hidden` columns (e.g., `password`)

```js
local user = await new User().findOrFail(1);
local obj  = user.toObject();
// { id: 1, name: "Alice", email: "alice@example.com", password: null, ... }
```

### `toJSON()` — returns a JSON string

```js
local json = user.toJSON();
```

### Using in HTTP responses

```js
class UserController {
    fn show(req, res) async {
        local user = await new User().findOrFail(req.params["id"]);
        res.status(200).json(user.toObject());
    }
}
```

---

## 17. QueryBuilder API Reference

> All methods that return `this` are chainable. Terminal methods are `async`.

### Projection

| Method | Returns | Description |
|--------|---------|-------------|
| `select(columns)` | `QueryBuilder` | Set columns to retrieve |

### Filtering

| Method | Returns | Description |
|--------|---------|-------------|
| `where(col, val)` | `QueryBuilder` | `col = val` |
| `where(col, op, val)` | `QueryBuilder` | `col op val` |
| `orWhere(col, val)` | `QueryBuilder` | OR `col = val` |
| `orWhere(col, op, val)` | `QueryBuilder` | OR `col op val` |
| `whereIn(col, arr)` | `QueryBuilder` | `col IN (...)` |
| `whereNotIn(col, arr)` | `QueryBuilder` | `col NOT IN (...)` |
| `whereNull(col)` | `QueryBuilder` | `col IS NULL` |
| `whereNotNull(col)` | `QueryBuilder` | `col IS NOT NULL` |
| `whereBetween(col, min, max)` | `QueryBuilder` | `col BETWEEN min AND max` |
| `whereRaw(sql, bindings)` | `QueryBuilder` | Raw SQL fragment |

### Ordering

| Method | Returns | Description |
|--------|---------|-------------|
| `orderBy(col, dir?)` | `QueryBuilder` | Order ASC by default |
| `orderByDesc(col)` | `QueryBuilder` | Order DESC |
| `latest(col?)` | `QueryBuilder` | DESC `created_at` (or custom) |
| `oldest(col?)` | `QueryBuilder` | ASC `created_at` (or custom) |

### Grouping

| Method | Returns | Description |
|--------|---------|-------------|
| `groupBy(col)` | `QueryBuilder` | GROUP BY column |
| `having(col, val)` | `QueryBuilder` | HAVING `col = val` |
| `having(col, op, val)` | `QueryBuilder` | HAVING `col op val` |

### Joins

| Method | Returns | Description |
|--------|---------|-------------|
| `join(table, localKey, fk)` | `QueryBuilder` | INNER JOIN |
| `leftJoin(table, localKey, fk)` | `QueryBuilder` | LEFT JOIN |
| `rightJoin(table, localKey, fk)` | `QueryBuilder` | RIGHT JOIN |

### Pagination controls

| Method | Returns | Description |
|--------|---------|-------------|
| `limit(n)` / `take(n)` | `QueryBuilder` | Max rows to return |
| `offset(n)` / `skip(n)` | `QueryBuilder` | Skip n rows |

### Soft-delete visibility

| Method | Returns | Description |
|--------|---------|-------------|
| `withTrashed()` | `QueryBuilder` | Include soft-deleted rows |
| `onlyTrashed()` | `QueryBuilder` | Only soft-deleted rows |

### Terminal methods (async)

| Method | Returns | Description |
|--------|---------|-------------|
| `get()` | `Model[]` | Execute and return all rows |
| `first()` | `Model \| null` | First matching row |
| `firstOrFail()` | `Model` | First row or raise error |
| `find(id)` | `Model \| null` | Find by primary key |
| `findOrFail(id)` | `Model` | Find by PK or raise error |
| `count()` | `number` | COUNT(*) |
| `sum(col)` | `number` | SUM(col) |
| `avg(col)` | `number` | AVG(col) |
| `min(col)` | `number` | MIN(col) |
| `max(col)` | `number` | MAX(col) |
| `exists()` | `bool` | `count() > 0` |
| `doesntExist()` | `bool` | `count() == 0` |
| `pluck(col)` | `any[]` | Flat array of one column |
| `paginate(page, perPage)` | `PaginationResult` | Full pagination with total |
| `simplePaginate(page, perPage)` | `SimplePaginationResult` | Lightweight pagination |
| `chunk(size, cb)` | `void` | Iterate in batches |
| `update(data)` | `result` | Bulk UPDATE |
| `delete()` | `result` | Bulk DELETE |
| `increment(col, n?)` | `result` | Atomic +n (default 1) |
| `decrement(col, n?)` | `result` | Atomic -n (default 1) |

---

## 18. DbContext

`DbContext` (`core/dbcontext.zs`) is a unified database adapter that supports both SQLite and MySQL/MariaDB. It is wired to the ORM automatically — any `Model` subclass instantiated after `DbContext.init()` inherits the connection.

### SQLite

```js
import { DbContext } from "./core/dbcontext";

const db = new DbContext({ type: "sqlite", path: "./app.sqlite" });

// In-memory (no persistence):
const db = new DbContext({ type: "sqlite", path: ":memory:" });
// Omitting path also defaults to :memory:
const db = new DbContext({ type: "sqlite" });
```

### MySQL / MariaDB

```js
import { DbContext } from "./core/dbcontext";

const db = new DbContext({
    type:     "mysql",
    host:     "127.0.0.1",
    user:     "root",
    password: "secret",
    database: "tinylms",
    port:     3306        // optional — defaults to 3306
});
```

### Subclassing DbContext

The recommended pattern is to extend `DbContext` and declare your models as instance properties. Because `DbContext.init()` calls `Model.setDB(this)` before returning, models created inside `init()` automatically pick up the connection.

```js
import { DbContext } from "../core/dbcontext";
import { User       } from "../model/user";
import { Post       } from "../model/post";

// Migrations (see §19)
import { CreateUsersTable } from "../migrations/create_users_table";
import { CreatePostsTable } from "../migrations/create_posts_table";

class AppDbContext (DbContext) {
    fn init(options) {
        base(this, options);             // connects + wires Model.setDB

        // ORM model accessors
        this.users = new User();
        this.posts = new Post();

        // Ordered list of all migrations (run in this order)
        this._migrations = [
            new CreateUsersTable(),
            new CreatePostsTable()
        ];
    }
}

// Create a single shared instance
const DB = new AppDbContext({
    type:     "mysql",
    host:     "127.0.0.1",
    user:     "root",
    password: "secret",
    database: "tinylms"
});
```

### Raw DDL

Use `exec()` to run arbitrary SQL statements synchronously (DDL, PRAGMA, etc.):

```js
db.exec("CREATE TABLE IF NOT EXISTS logs (id INTEGER PRIMARY KEY, msg TEXT)");
db.exec("PRAGMA journal_mode=WAL");
```

### Transactions

```js
db.beginTransaction();
try {
    // ... perform multiple operations ...
    db.commitTransaction();
} catch (err) {
    db.rollbackTransaction();
}
```

`beginTransaction()` emits `BEGIN` for SQLite and `START TRANSACTION` for MySQL.

### Closing the connection

```js
db.close();
```

---

## 19. Migrations

The migration system (`core/migration.zs`) tracks which schema changes have been applied, grouped into numbered batches. It is intentionally similar to Laravel's migration workflow.

### Defining a migration

Create a file per migration. Extend `Migration` and override `up()` (apply) and `down()` (undo). The `name()` method returns the class name by default and is used as the stable identifier in the `migrations` tracking table.

```js
import { Migration } from "../core/migration";

class CreateUsersTable (Migration) {
    fn init() { base(this); }

    fn up(schema) {
        schema.create("users", fn(t) {
            t.id();
            t.string("name", 100).notNull();
            t.string("email", 191).unique();
            t.string("password", 255).notNull();
            t.boolean("is_admin").defaultVal(false);
            t.timestamps();
            t.softDeletes();
        });
    }

    fn down(schema) {
        schema.drop("users");
    }
}
```

> Override `name()` when you rename the class so old history entries still match:
> ```js
> fn name() { return "CreateUsersTable"; }
> ```

### Registering migrations

Add migration instances to `this._migrations` in your `AppDbContext`, **in the order they should run**:

```js
class AppDbContext (DbContext) {
    fn init(options) {
        base(this, options);
        this.users = new User();

        this._migrations = [
            new CreateUsersTable(),
            new CreatePostsTable(),
            new AddRoleToUsersTable()
        ];
    }
}
```

### Running from the CLI

`backend/migrate.zs` is the CLI entry point. Run it with `zscript`:

```bash
# Apply all pending migrations
zscript --run ./backend/migrate.zs migrate

# Print the status of every migration
zscript --run ./backend/migrate.zs status

# Roll back the last batch
zscript --run ./backend/migrate.zs rollback

# Roll back the last 3 batches
zscript --run ./backend/migrate.zs rollback --steps 3

# Drop every table then re-run all migrations from scratch
zscript --run ./backend/migrate.zs fresh
```

> `migrate` is the default command — omitting it has the same effect.

### Blueprint column types

`schema.create(table, fn(t) { … })` passes a `Blueprint` (`t`) whose factory methods each return a `ColumnDef` you can immediately chain modifiers on.

| Factory | SQL type (SQLite) | SQL type (MySQL) |
|---------|-------------------|-----------------|
| `t.id(name?)` | `INTEGER PRIMARY KEY AUTOINCREMENT` | `INT UNSIGNED AUTO_INCREMENT PRIMARY KEY` |
| `t.bigId(name?)` | `INTEGER PRIMARY KEY AUTOINCREMENT` | `BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY` |
| `t.string(name, length?)` | `TEXT` | `VARCHAR(length)` |
| `t.char(name, length?)` | `TEXT` | `CHAR(length)` |
| `t.text(name)` | `TEXT` | `TEXT` |
| `t.mediumText(name)` | `TEXT` | `MEDIUMTEXT` |
| `t.longText(name)` | `TEXT` | `LONGTEXT` |
| `t.integer(name)` | `INTEGER` | `INT` |
| `t.bigInteger(name)` | `INTEGER` | `BIGINT` |
| `t.smallInteger(name)` | `INTEGER` | `SMALLINT` |
| `t.tinyInteger(name)` | `INTEGER` | `TINYINT` |
| `t.float(name)` | `REAL` | `FLOAT` |
| `t.double(name)` | `REAL` | `DOUBLE` |
| `t.decimal(name, precision?, scale?)` | `NUMERIC(p,s)` | `DECIMAL(p,s)` |
| `t.boolean(name)` | `INTEGER` | `TINYINT(1)` |
| `t.json(name)` | `TEXT` | `JSON` |
| `t.blob(name)` | `BLOB` | `BLOB` |
| `t.date(name)` | `TEXT` | `DATE` |
| `t.dateTime(name)` | `TEXT` | `DATETIME` |
| `t.time(name)` | `TEXT` | `TIME` |
| `t.timestamp(name)` | `BIGINT` | `BIGINT` (Unix ms) |
| `t.timestamps()` | Adds `created_at` + `updated_at` as nullable BIGINT | same |
| `t.softDeletes(col?)` | Adds `deleted_at` nullable BIGINT | same |
| `t.foreign(name)` | `INTEGER UNSIGNED` (for FK columns) | `BIGINT UNSIGNED` |

### Column modifiers

All modifiers return the `ColumnDef` so they can be chained:

```js
t.string("email", 191).notNull().unique();
t.boolean("active").defaultVal(true);
t.integer("sort_order").unsigned().defaultVal(0).nullable();
t.bigInteger("post_id").unsigned().references("posts", "id");
```

| Modifier | Description |
|----------|-------------|
| `.nullable()` | Allow NULL values |
| `.notNull()` | Disallow NULL (this is the default) |
| `.defaultVal(val)` | Column default value |
| `.unique()` | Add UNIQUE constraint on this column |
| `.unsigned()` | Mark numeric column as UNSIGNED (MySQL; ignored by SQLite) |
| `.autoIncrement()` | Add AUTO_INCREMENT / AUTOINCREMENT |
| `.primary()` | Mark as PRIMARY KEY |
| `.references(table, col?)` | Add FOREIGN KEY → `table(col)` (default col: `"id"`) |

### Blueprint constraint helpers

```js
schema.create("role_user", fn(t) {
    t.foreign("user_id").references("users");
    t.foreign("role_id").references("roles");

    // Multi-column UNIQUE constraint (emitted inline in CREATE TABLE)
    t.unique(["user_id", "role_id"]);

    // CREATE INDEX statement (emitted after CREATE TABLE)
    t.index(["role_id"], "role_user_role_idx");
});
```

### MigrationRunner API

You rarely need to use `MigrationRunner` directly — the CLI does it for you. But you can drive it programmatically:

```js
import { MigrationRunner } from "./core/migration";
import { DB               } from "./db/dbcontext";

const runner = new MigrationRunner(DB);

await runner.migrate(DB._migrations);          // run pending
await runner.rollback(DB._migrations);         // undo last batch
await runner.rollback(DB._migrations, 2);      // undo last 2 batches
await runner.fresh(DB._migrations);            // drop all + re-migrate
await runner.status(DB._migrations);           // print status table
```

| Method | Description |
|--------|-------------|
| `migrate(migrations)` | Run all pending migrations; record each in batch N+1 |
| `rollback(migrations, steps?)` | Reverse the last `steps` batches (default: 1) |
| `fresh(migrations)` | Call every `down()` in reverse, drop `migrations` table, re-run `migrate()` |
| `status(migrations)` | Print a coloured table showing Ran / Pending for each migration |

---

## 20. HTTP Server — ZServer

`ZServer` (`core/server.zs`) wraps `core:mongoose`'s `Server` and automatically prefixes every route with a configurable base path (default: `/api`). A singleton named `APP` is exported.

### Quick start

```js
import { APP } from "./core/server";

APP.get("/health", fn(req, res) {
    res.status(200).json({ ok: true });
});

APP.run(3000, fn() {
    println("Listening on :3000");
});
```

### Routing

Methods map 1-to-1 to HTTP verbs. The path is automatically prefixed with the base path (`/api` by default).

```js
import { APP } from "./core/server";

// GET /api/users
APP.get("/users", fn(req, res) async {
    local users = await DB.users.all();
    res.status(200).json(users);
});

// POST /api/users
APP.post("/users", fn(req, res) async {
    local user = await DB.users.create(req.body);
    res.status(201).json(user.toObject());
});

// PUT /api/users/:id
APP.put("/users/:id", fn(req, res) async {
    local user = await DB.users.findOrFail(req.params["id"]);
    await user.update(req.body);
    res.status(200).json(user.toObject());
});

// DELETE /api/users/:id
APP.delete("/users/:id", fn(req, res) async {
    local user = await DB.users.findOrFail(req.params["id"]);
    await user.delete();
    res.status(204).send();
});

// Other supported verbs: .patch(), .head(), .options()
```

Change the base path before registering any routes:

```js
APP.setPath("v1");    // routes become /v1/...
APP.setPath("");      // no prefix
```

### Controller routing

`ZServer.controller()` instantiates a controller class, injects services, automatically derives a route prefix from the class name (strips the `Controller` suffix), and provides a scoped `router` object for clean route definitions.

```js
import { APP } from "./core/server";
import { UserController } from "./controllers/user";

APP.controller(UserController, fn(router, instance) {
    // Routes become: /api/User/<path>
    // (or /api/user/<path> — matches the stripped class name exactly)
    router.get("/:id", "show");       // GET  /api/User/:id  → instance.show
    router.post("/",   "store");      // POST /api/User/     → instance.store
    router.put("/:id", "update");     // PUT  /api/User/:id  → instance.update
    router.delete("/:id", "destroy"); // DELETE /api/User/:id → instance.destroy
});
```

Services registered via `APP.add()` are injected into the controller before `callback` runs:

```js
APP.add("db", DB);
APP.add("mailer", Mailer);

// Inside UserController.init():
// this.services["db"]     → DB
// this.services["mailer"] → Mailer
```

### Middleware

Register global middleware (executed for every request) with `use()`:

```js
import { APP } from "./core/server";

// CORS headers
APP.use(fn(req, res, next) {
    res.setHeader("Access-Control-Allow-Origin", "*");
    next();
});

// Request logger
APP.use(fn(req, res, next) async {
    println(req.method + " " + req.url);
    next();
});
```

### ZServer API reference

| Method | Description |
|--------|-------------|
| `setPath(path)` | Set the global route prefix (default: `"api"`) |
| `add(key, value)` | Store a named service for injection into controllers |
| `use(callback)` | Register global middleware `(req, res, next)` |
| `get(path, cb)` | Register a GET handler |
| `post(path, cb)` | Register a POST handler |
| `put(path, cb)` | Register a PUT handler |
| `delete(path, cb)` | Register a DELETE handler |
| `patch(path, cb)` | Register a PATCH handler |
| `head(path, cb)` | Register a HEAD handler |
| `options(path, cb)` | Register an OPTIONS handler |
| `controller(cls, cb)` | Register a controller with auto-prefixed routes |
| `run(port, cb?)` | Start the HTTP server on `port` |

---

## 21. Controller

`Controller` (`core/controller.zs`) is a minimal base class for HTTP controllers. Extend it to group related route handlers and receive injected services.

```js
import { Controller } from "./core/controller";

class UserController (Controller) {
    fn init() {
        base(this);
        // this.services is populated by ZServer.controller() before any
        // route handler runs — access it anywhere in the class.
    }

    fn show(req, res) async {
        local db   = this.services["db"];
        local user = await db.users.findOrFail(req.params["id"]);
        res.status(200).json(user.toObject());
    }

    fn store(req, res) async {
        local db   = this.services["db"];
        local user = await db.users.create(req.body);
        res.status(201).json(user.toObject());
    }

    fn update(req, res) async {
        local db   = this.services["db"];
        local user = await db.users.findOrFail(req.params["id"]);
        await user.update(req.body);
        res.status(200).json(user.toObject());
    }

    fn destroy(req, res) async {
        local db   = this.services["db"];
        local user = await db.users.findOrFail(req.params["id"]);
        await user.delete();
        res.status(204).send();
    }
}
```

Register it with the server:

```js
import { APP } from "./core/server";
import { UserController } from "./controllers/user";

APP.add("db", DB);

APP.controller(UserController, fn(router) {
    router.get("/:id", "show");
    router.post("/",   "store");
    router.put("/:id", "update");
    router.delete("/:id", "destroy");
});
```

### `Controller` API

| Member | Description |
|--------|-------------|
| `this.services` | Plain object populated by `ZServer.controller()` with all services registered via `APP.add()` |
| `setService(services)` | Called internally by `ZServer` — no need to call this manually |


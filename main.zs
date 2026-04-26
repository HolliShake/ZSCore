import { APP } from "./core/server";
import { DB } from "./db/dbcontext";
import { UserController } from "./controllers/user";
import { User } from "./models/user";
import { println } from  "core:io";

println("======================  TINYLMS BACKEND ====================== ");

APP.add("db", DB);

APP.controller(UserController, fn(app, ctrl) {
    app.get("/index", "index");
    app.get("/show/:id", "show");
    app.post("/store", "store");
    app.put("/update/:id", "update");
});

APP.run(3002, println);
import { DbContext } from  "../core/dbcontext";
import { TABLES } from "./tables";

class AppDbContext (DbContext) {
    fn init(options) {
        base(this, options);  // DbContext.init wires Model.setDB(this) automatically

        for (i:=0;i<TABLES.length();i++) {
            this.users = new TABLES[i];
        }
    }
}

const DB = new AppDbContext({
    type:     "mysql",
    host:     "127.0.0.1",
    user:     "root",
    password: "andy404",
    database: "zscript_test",
    port:     3306
});
import { println } from "core:io";
import { Controller } from "../core/controller";

class UserController (Controller) {
    fn init() {
        base(this);
    }

    fn index(req, res) async {
        res.status(200).json({ message: "Hello" });
    }

    fn show(req, res) async {
        const id = req.params["id"];
        res.status(200).json({ id: id });
    }


}

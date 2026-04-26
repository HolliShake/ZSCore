import { Server } from "core:mongoose";
import { Object } from "core:object";
import { println, format } from "core:io";
import { endsWith, replace } from "core:string";
import { normalize } from "core:path";

const ControllerSuffix = "Controller";

class ZServer {
    fn init() {
        this._path = "api";
        this._srv  = new Server();
        this._services = {};
    }

    fn setPath(path) {
        this._path = path;
    }

    /**
     * Docs here!
     */
    fn add(key, value) {
        this._services[key] = value;
    }

    /**
     * Docs here!
     */
    fn controller(cls, callback) {
        const instance = new cls();

        try {
            instance.setService(this._services);
            println("Service injected...");
        } catch (err) {
            println(err);
        }

        local prefix = typeof(instance);

        if (endsWith(prefix,  ControllerSuffix) && prefix != ControllerSuffix) {
            prefix = replace(prefix, ControllerSuffix, "");
        }

        const wrapper = Object.freeze({
            get: fn(path, method) {
                this.get(normalize(format("/{}/{}", prefix, path)), fn(req, res) async => await instance[method](req, res));
            },
            post: fn(path, method) {
                this.post(normalize(format("/{}/{}", prefix, path)), fn(req, res) async => await instance[method](req, res));
            },
            put: fn(path, method) {
                this.put(normalize(format("/{}/{}", prefix, path)), fn(req, res) async => await instance[method](req, res));
            },
            delete: fn(path, method) {
                this.delete(normalize(format("/{}/{}", prefix, path)), fn(req, res) async => await instance[method](req, res));
            },
            patch: fn(path, method) {
                this.patch(normalize(format("/{}/{}", prefix, path)), fn(req, res) async => await instance[method](req, res));
            },
            head: fn(path, method) {
                this.head(normalize(format("/{}/{}", prefix, path)), fn(req, res) async => await instance[method](req, res));
            },
            options: fn(path, method) {
                this.options(normalize(format("/{}/{}", prefix, path)), fn(req, res) async => await instance[method](req, res));
            }
           
        });

        callback(wrapper, instance);
    }

    /**
     * Docs here!
     */
    fn use(callback) {
        this._srv.use(callback);
    }

    /**
     * Docs here!
     */
    fn get(path, callback) {
        this._srv.get(normalize(format("/{}/{}", this._path, path)), callback);
    }

    /**
     * Docs here!
     */
    fn post(path, callback) {
        this._srv.post(normalize(format("/{}/{}", this._path, path)), callback);
    }

    /**
     * Docs here!
     */
    fn put(path, callback) {
        this._srv.put(normalize(format("/{}/{}", this._path, path)), callback);
    }

    /**
     * Docs here!
     */
    fn delete(path, callback) {
        this._srv.delete(normalize(format("/{}/{}", this._path, path)), callback);
    }

    /**
     * Docs here!
     */
    fn patch(path, callback) {
        this._srv.patch(normalize(format("/{}/{}", this._path, path)), callback);
    }

    /**
     * Docs here!
     */
    fn head(path, callback) {
        this._srv.head(normalize(format("/{}/{}", this._path, path)), callback);
    }

    /**
     * Docs here!
     */
    fn options(path, callback) {
        this._srv.options(normalize(format("/{}/{}", this._path, path)), callback);
    }

    /**
     * Docs here!
     */
    fn run(port, cb) {
        this._srv.listen(port, cb);
    }
}


const APP = new ZServer();
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
var WSServer = require("websocket").server;
exports.newWebsocketServer = function (config) {
    return function () {
        return new WSServer(config);
    };
};
exports.newWebsocketServerImpl = function (config) { return function (e, s) { return s(new WSServer(config)); }; };
exports.onRequest = function (server) {
    return function (callback) {
        return function () {
            server.on("request", function (req) {
                callback(req)();
            });
        };
    };
};
exports.onRequestImpl = function (server) { return function (callback) { return function (e, s) {
    server.on("request", function (req) {
        callback(req)();
    });
    s();
}; }; };
exports.onConnect = function (server) {
    return function (callback) {
        return function () {
            server.on("connect", function (conn) {
                conn.birth = Date.now();
                callback(conn)();
            });
        };
    };
};
exports.onClose = function (server) {
    return function (callback) {
        return function () {
            server.on("close", function (conn, reason, description) {
                callback(conn)(reason)(description)();
            });
        };
    };
};
exports.onCloseImpl = function (server) { return function (cb) { return function (e, s) {
    server.on("close", function (conn, reason, desc) {
        cb(conn)(reason)(desc)();
    });
    s();
}; }; };
exports.shutdown = function (server) { return function () { return server.shutDown(); }; };
exports.shutdownImpl = function (server) { return function (e, s) { server.shutDown(); s(); }; };

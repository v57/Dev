#!/usr/bin/env python3
"""A reference Localization Server for Dev (docs/localization-server-api.md).

Standard library only: SQLite storage, five POST routes, bearer auth.

    LOCALIZE_KEY=secret python3 localization_server.py --db strings.sqlite --port 8080
    python3 localization_server.py --db strings.sqlite --add "Reset password" --namespace auth

Then add http://127.0.0.1:8080/ in Dev's sidebar (Servers > Add Connection) with the same key.
Copy the rules into your own backend; the storage is the part you will replace.
"""

import argparse
import json
import os
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCHEMA = """
CREATE TABLE IF NOT EXISTS messages (
  source    TEXT PRIMARY KEY,
  namespace TEXT NOT NULL DEFAULT '',
  comment   TEXT,
  revision  INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS locales (code TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS vals (
  source TEXT NOT NULL REFERENCES messages(source) ON DELETE CASCADE,
  locale TEXT NOT NULL,
  value  TEXT NOT NULL,
  origin TEXT NOT NULL CHECK (origin IN ('gold', 'machine', 'imported')),
  model  TEXT,
  stale  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source, locale)
);
"""

MAX_PAGE = 1000


class ApiError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def page_args(body):
    limit = max(1, min(int(body.get("limit") or 200), MAX_PAGE))
    offset = int(body.get("cursor") or 0)
    return limit, offset


def page(items, limit, offset):
    more = len(items) > limit
    items = items[:limit]
    return {"items": items, "cursor": str(offset + limit) if more else None, "more": more}


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.executescript(SCHEMA)

    # -- routes

    def stats(self, body):
        wanted = body.get("locales")
        codes = [r["code"] for r in self.db.execute("SELECT code FROM locales ORDER BY code")]
        if wanted:
            codes = [c for c in codes if c in wanted]
        total = self.db.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        commented = self.db.execute(
            "SELECT COUNT(*) FROM messages WHERE comment IS NOT NULL AND comment != ''").fetchone()[0]
        rows = []
        for code in codes:
            counts = dict(self.db.execute(
                "SELECT origin, COUNT(*) FROM vals WHERE locale = ? GROUP BY origin", (code,)).fetchall())
            filled = sum(counts.values())
            stale = self.db.execute(
                "SELECT COUNT(*) FROM vals WHERE locale = ? AND stale = 1", (code,)).fetchone()[0]
            rows.append({"locale": code, "total": total, "machine": counts.get("machine", 0),
                         "gold": counts.get("gold", 0), "missing": total - filled, "stale": stale})
        return {"messages": total, "commented": commented, "rows": rows}

    def messages(self, body):
        limit, offset = page_args(body)
        locale = body.get("locale")
        where, args = [], []
        if body.get("namespace"):
            where.append("namespace = ?")
            args.append(body["namespace"])
        if body.get("comment") == "missing":
            where.append("(comment IS NULL OR comment = '')")
        sql = "SELECT * FROM messages" + (" WHERE " + " AND ".join(where) if where else "")
        sql += " ORDER BY source LIMIT ? OFFSET ?"
        items = []
        for m in self.db.execute(sql, (*args, limit + 1, offset)):
            locales = {}
            if locale:
                v = self.db.execute("SELECT * FROM vals WHERE source = ? AND locale = ?",
                                    (m["source"], locale)).fetchone()
                if v:
                    locales[locale] = {"value": v["value"], "origin": v["origin"], "stale": bool(v["stale"])}
            items.append({"source": m["source"], "comment": m["comment"], "namespace": m["namespace"],
                          "revision": m["revision"], "locales": locales})
        return page(items, limit, offset)

    def worklist(self, body):
        locale = body.get("locale")
        if not locale:
            raise ApiError(400, "locale is required")
        limit, offset = page_args(body)
        condition = {
            "empty": "v.source IS NULL",
            "stale": "v.origin = 'machine' AND v.stale = 1",
            "machine": "v.origin = 'machine'",
            "all": "1",
        }.get(body.get("filter") or "empty")
        if condition is None:
            raise ApiError(400, "filter must be empty, stale, machine or all")
        sql = f"""SELECT m.*, v.value, v.origin, v.stale FROM messages m
                  LEFT JOIN vals v ON v.source = m.source AND v.locale = ?
                  WHERE {condition} ORDER BY m.source LIMIT ? OFFSET ?"""
        items = [{"source": r["source"], "comment": r["comment"], "namespace": r["namespace"],
                  "locale": locale, "revision": r["revision"], "value": r["value"],
                  "origin": r["origin"], "stale": bool(r["stale"])}
                 for r in self.db.execute(sql, (locale, limit + 1, offset))]
        return page(items, limit, offset)

    def values(self, body):
        entries = body.get("entries") or []
        if len(entries) > MAX_PAGE:
            raise ApiError(400, f"at most {MAX_PAGE} entries per request")
        written = skipped = 0
        reasons = set()
        with self.db:
            for e in entries:
                source, locale, value = e.get("source"), e.get("locale"), e.get("value")
                origin = e.get("origin") or "machine"
                if not source or not locale or value is None or origin not in ("gold", "machine", "imported"):
                    skipped += 1
                    reasons.add("malformed entry")
                    continue
                if not self.db.execute("SELECT 1 FROM messages WHERE source = ?", (source,)).fetchone():
                    skipped += 1
                    reasons.add("unknown source")
                    continue
                current = self.db.execute("SELECT origin FROM vals WHERE source = ? AND locale = ?",
                                          (source, locale)).fetchone()
                # Rule 1: a machine value never overwrites a human's.
                if origin == "machine" and current and current["origin"] == "gold":
                    skipped += 1
                    reasons.add("a gold value is never overwritten by a machine value")
                    continue
                self.db.execute("INSERT OR IGNORE INTO locales(code) VALUES (?)", (locale,))
                self.db.execute(
                    """INSERT INTO vals(source, locale, value, origin, model, stale) VALUES (?, ?, ?, ?, ?, 0)
                       ON CONFLICT(source, locale) DO UPDATE SET
                         value = excluded.value, origin = excluded.origin, model = excluded.model, stale = 0""",
                    (source, locale, value, origin, e.get("model")))
                written += 1
        return {"written": written, "skipped": skipped, "stale": 0,
                "reason": "; ".join(sorted(reasons)) or None}

    def comments(self, body):
        entries = body.get("entries") or []
        if len(entries) > MAX_PAGE:
            raise ApiError(400, f"at most {MAX_PAGE} entries per request")
        written = stale = 0
        with self.db:
            for e in entries:
                row = self.db.execute("SELECT comment FROM messages WHERE source = ?",
                                      (e.get("source"),)).fetchone()
                if not row or (row["comment"] or "") == (e.get("comment") or ""):
                    continue
                # Rule 2: a changed comment bumps the revision and stales machine values.
                self.db.execute("UPDATE messages SET comment = ?, revision = revision + 1 WHERE source = ?",
                                (e.get("comment"), e["source"]))
                stale += self.db.execute(
                    "UPDATE vals SET stale = 1 WHERE source = ? AND origin = 'machine' AND stale = 0",
                    (e["source"],)).rowcount
                written += 1
        return {"written": written, "stale": stale}

    # -- your app's side

    def add(self, source, namespace="", comment=None, locales=()):
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO messages(source, namespace, comment) VALUES (?, ?, ?)",
                            (source, namespace, comment))
            for code in locales:
                self.db.execute("INSERT OR IGNORE INTO locales(code) VALUES (?)", (code,))


ROUTES = {"stats", "messages", "worklist", "values", "comments"}


def make_handler(store, key):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            try:
                if not key:
                    raise ApiError(503, "the server has no LOCALIZE_KEY configured")
                if self.headers.get("Authorization", "") != f"Bearer {key}":
                    raise ApiError(401, "missing or wrong key")
                prefix = "/localize/"
                route = self.path.split("?")[0]
                route = route[len(prefix):] if route.startswith(prefix) else ""
                if route not in ROUTES:
                    raise ApiError(404, f"no route {self.path}")
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                self.reply(200, {"data": getattr(store, route)(body)})
            except ApiError as error:
                self.reply(error.code, {"error": {"code": error.code, "message": error.message}})
            except (ValueError, TypeError) as error:
                self.reply(400, {"error": {"code": 400, "message": str(error)}})

        def reply(self, status, payload):
            data = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--db", default="strings.sqlite")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--add", metavar="SOURCE", help="add a message and exit")
    parser.add_argument("--namespace", default="")
    parser.add_argument("--comment")
    parser.add_argument("--locales", default="", help="comma-separated target locales to serve, e.g. de,fr,ja")
    args = parser.parse_args()

    store = Store(args.db)
    locales = [code for code in args.locales.split(",") if code]
    if args.add:
        store.add(args.add, args.namespace, args.comment, locales)
        return
    for code in locales:
        store.db.execute("INSERT OR IGNORE INTO locales(code) VALUES (?)", (code,))
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(store, os.environ.get("LOCALIZE_KEY")))
    print(f"Localization Server on http://127.0.0.1:{args.port}/ ({args.db})")
    server.serve_forever()


if __name__ == "__main__":
    main()

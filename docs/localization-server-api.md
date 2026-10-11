# Localization Server API

Dev translates an app's String Catalogs. If your **server** also has user-facing text (emails, push
notifications, web pages, error messages), it can expose that text through this API, and Dev will
translate it with the same pipeline: the model you chose in Settings, learning from values a human
already approved, placeholder checks, and a review table.

Add the server in Dev's sidebar under **Servers** → **Add Connection** with its endpoint and key.

A complete reference server (Python, standard library only, SQLite) is in
[`examples/localization_server.py`](examples/localization_server.py).

## Basics

- Every route is `POST <endpoint>/localize/<route>` with a JSON body.
- Auth: `Authorization: Bearer <key>`. Dev stores the key in the login keychain; a server with no
  key of its own uses `LOCALIZE_KEY` from Dev's environment.
- Success: `200` with `{ "data": … }`.
- Failure: any non-2xx with `{ "error": { "code": <int>, "message": "<text>" } }`.
  - `401`: the key is missing or wrong.
  - `503`: the server itself has no key configured.
- Lists are paged: a request takes `limit` (at most 1000) and `cursor`; a reply carries `cursor` and
  `more`. Dev keeps asking with the returned `cursor` while `more` is true. The cursor is opaque to
  Dev.
- Sources are English. A **message** is identified by its source text (`source`).

## Vocabulary

| Term | Meaning |
|---|---|
| `source` | The English text, the message's identity. |
| `namespace` | A grouping you choose (a feature, a mail template, a screen). Dev can scope a run to one. |
| `comment` | Context for the translator. Dev sends it with the source and can write it. |
| `revision` | An integer you bump whenever the source or comment changes. |
| `origin` | Who wrote a value: `gold` (a human), `machine` (a model), or `imported`. |
| `stale` | A `machine` value whose message changed after it was written; it should be redone. |

Rules the server enforces (Dev relies on them):

1. **A `machine` value never overwrites a `gold` one.** Report it as skipped.
2. Changing a comment bumps the revision and marks that message's `machine` values `stale`.
   `gold` values are never marked.
3. A source with no letter or digit outside its placeholders is never translated. Dev skips them too.

Placeholders Dev keeps intact: printf (`%@`, `%d`, `%1$@`, `%lld`, …), `{name}`, `{{name}}`,
`$name` and `${name}`.

## Routes

### `localize/stats`

What the server holds. Dev uses it to check a connection, so it should be cheap and write nothing.

Request: `{ "locales": ["de", "fr"] }` (optional; omit for all locales).

```json
{ "data": {
  "messages": 1240,
  "commented": 980,
  "rows": [
    { "locale": "de", "total": 1240, "machine": 900, "gold": 300, "missing": 40, "stale": 12 }
  ]
} }
```

`rows` lists every target locale the server serves; Dev's locale picker is built from it.

### `localize/messages`

One page of the inventory: every message with its comment, namespace and, when `locale` is given,
that locale's value.

Request:

```json
{ "locale": "de", "namespace": "mail", "comment": "missing", "limit": 200, "cursor": null }
```

All fields are optional. `comment: "missing"` lists only messages with no comment.

```json
{ "data": {
  "items": [
    { "source": "Your order has shipped", "comment": "Push notification title",
      "namespace": "orders", "revision": 3,
      "locales": { "de": { "value": "Deine Bestellung ist unterwegs", "origin": "gold", "stale": false } } }
  ],
  "cursor": "200", "more": true
} }
```

`locales` holds only the requested locale (or none when no locale was given). A message with no
value in it has no entry.

### `localize/worklist`

What still needs work in one locale.

Request: `{ "locale": "de", "filter": "empty", "limit": 1000, "cursor": null }`

| `filter` | Returns |
|---|---|
| `empty` | Messages with no value in the locale. |
| `stale` | Messages whose `machine` value is stale. |
| `machine` | Messages with a `machine` value. |
| `all` | Every message. |

```json
{ "data": {
  "items": [
    { "source": "Reset password", "comment": "Button", "namespace": "auth",
      "locale": "de", "revision": 1, "value": null, "origin": null, "stale": false }
  ],
  "cursor": null, "more": false
} }
```

A run reads `empty`, then `stale`, page by page, and writes each batch as soon as it is translated,
so a cancelled run keeps what it wrote.

### `localize/values`

Writes translations (at most 1000 entries per request).

```json
{ "entries": [
  { "source": "Reset password", "locale": "de", "value": "Passwort zurücksetzen",
    "origin": "machine", "model": "claude-haiku-5-5" }
] }
```

`origin` is `machine` for a run's output and `gold` when a person edits a value in Dev's table.
`model` is present on machine values.

```json
{ "data": { "written": 1, "skipped": 0, "stale": 0, "reason": null } }
```

`skipped` counts entries refused under rule 1; `reason` says why. An entry for an unknown source is
also skipped. Writing a value clears that value's `stale` flag.

### `localize/comments`

Writes comments (at most 1000 entries per request).

```json
{ "entries": [ { "source": "Reset password", "comment": "Button on the sign-in screen" } ] }
```

```json
{ "data": { "written": 1, "stale": 2 } }
```

A changed comment bumps the revision and marks the message's `machine` values stale (`stale` counts
them). An unchanged comment is not a change.

## Testing your server

```bash
curl -s -X POST http://127.0.0.1:8080/localize/stats \
  -H "Authorization: Bearer $LOCALIZE_KEY" -H "Content-Type: application/json" -d '{}'
```

Then add it in Dev: the sidebar row turns green and shows the message count.

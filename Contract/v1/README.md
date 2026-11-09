# Gateway contract, `/v1`

These JSON files are the contract between Clew's Gateway (Swift) and its clients
(the Chrome extension in `Extension/`). Both sides test against them: the Swift
tests decode each file into the Gateway's types and re-encode it unchanged; the
extension's tests type-check and parse the same files. Change a file here and both
test suites must pass again.

| File | Endpoint |
|---|---|
| `hello.response.json` | `GET /v1/hello?nonce=…&client=…` (`proof` only for a known client) |
| `pair.request.json`, `pair.response.json` | `POST /v1/pair` |
| `import.request.json`, `import.response.json` | `POST /v1/import`, `Authorization: Bearer <token>` |
| `failure.response.json` | any error: `{"error": "…"}` with a 4xx/5xx status |

Every request must carry `Host: 127.0.0.1:<port>`; an `Origin`, if present, must be
the extension's. Clew listens on the first free port of 39271–39275.

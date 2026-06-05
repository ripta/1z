# HTTP

`lib/net/http.1z` is a small HTTP/1.1 server library. It exposes a parser
for the request line and headers, a `request` value the handler reads from,
a `response` value the handler returns, and a `serve` entry point that
accepts connections and dispatches them to a user-supplied handler. Higher
layers -- routing in `lib/net/http/router.1z`, static-file serving via
`serve-static` -- compose on top.

## Handler Shape

A handler is a quotation with the stack effect `( stream request -- )`. The
runtime hands it the per-connection stream and a populated `request`; the
handler writes its response back through the same stream. The stream is
closed automatically once the handler returns.

```
use "net/http" ;

"127.0.0.1" 18080 [
  \ stack: stream request
  path>> "text/plain" ok            \ stack: stream response
  send-response
] serve
```

The handler consumes the `request` value to build the response, then
hands the stream and response to `send-response`. The stream itself is
not consumed by the handler -- `serve` closes it on the way out.

`serve` blocks forever and creates its own `task-scope`; each accepted
connection runs the handler in a child task, so I/O inside the handler is
transparently asynchronous.

## Request Fields

`request` carries three categories of data. The wire-derived fields are
parsed from the HTTP request line and headers. The socket-derived fields
come from the accepted connection and the server config. The TLS-derived
fields describe the handshake; under plaintext HTTP they ride sentinel
defaults until server-side TLS lands.

| Field | Source | Notes |
|-------|--------|-------|
| `method>>` | wire | Request method, uppercased as sent. |
| `path>>` | wire | Path portion of the request-target, split at the first `?`. |
| `query-string>>` | wire | Everything after the first `?`; empty string when absent. |
| `version>>` | wire | Protocol version string from the request line. |
| `headers>>` | wire | Hash with lowercased keys. |
| `remote-addr>>` | socket | Peer IP as a string. |
| `remote-port>>` | socket | Peer port as a fixnum. |
| `server-name>>` | server config | The `host` value passed to `serve`. |
| `server-port>>` | server config | The `port` value passed to `serve`. |
| `is-tls?>>` | TLS | `f` under plaintext; `t` once server TLS lands. |
| `tls-version>>` | TLS | Empty string under plaintext. |
| `tls-cipher>>` | TLS | Empty string under plaintext. |

`read-request`, which parses a stream into a `request` directly, populates
only the wire-derived fields and rides sentinel defaults for the rest. The
socket-derived and TLS-derived fields are populated by `serve`'s dispatch
path before the handler runs.

A handler that logs the remote address, looks up a header, and echoes the
path looks like this:

```
use "net/http" ;

"127.0.0.1" 18080 [
  \ stack: stream request
  dup remote-addr>> print " " print
  dup headers>> "user-agent" @get? "(unknown)" unwrap-or print-line
  path>> "text/plain" ok send-response
] serve
```

`headers>> "user-agent" @get?` returns an option since the header may be
absent; `unwrap-or` supplies the fallback string.

## Building Responses

`<response>: ( status reason content-type body -- response )` is the raw
constructor. The library wraps the common cases:

| Word | Stack effect | Purpose |
|------|--------------|---------|
| `ok` | `( body content-type -- response )` | 200 with the given body and Content-Type. |
| `not-found` | `( -- response )` | 404 with a plain-text body. |
| `method-not-allowed` | `( -- response )` | 405 with a plain-text body. |
| `error-response` | `( status reason message -- response )` | Arbitrary status with a plain-text body. |

`send-response: ( stream response -- )` serializes a response to the wire
and writes it in a single call. The wire format is HTTP/1.1 with
`Connection: close` and an automatic `Content-Length`.

## Reading Form Bodies

`read-form: ( stream length -- form )` decodes an
`application/x-www-form-urlencoded` body of exactly `length` bytes into a
hash of decoded keys to decoded values. The caller looks up
`Content-Length` from the request headers and passes the length
explicitly:

```
use "net/http" ;

\ inside a handler with ( stream request -- )
2dup headers>> "content-length" @get >fixnum   \ stack: stream request stream length
read-form                                      \ stack: stream request form
```

`read-form` throws `EUnexpectedEOF` if the stream reaches EOF before
`length` bytes are available; this catches a truncated body before the
next pipelined request gets eaten as form bytes. It throws
`EInvalidArgument` on malformed percent sequences.

Empty segments and segments without `=` follow the WHATWG
`application/x-www-form-urlencoded` parser: empty segments are dropped,
bare keys produce empty values.

## Routing

`lib/net/http/router.1z` ships a path router shaped after Go's
`http.ServeMux`. Routes are registered against a builder, the builder is
finalized into a `( stream request -- )` quotation, and that quotation is
passed to `serve`:

```
use "net/http" ;
use "net/http/router" ;

"127.0.0.1" 18080
<router>
"/healthz" [ drop "ok" "text/plain" ok ] route
"/" [
  path>> "/" =
  [ "welcome" "text/plain" ok ]
  [ not-found ]
  if
] route
build                                          \ ( stream request -- ) quotation
serve
```

A trailing `/` in the registered path matches any URL with that prefix;
non-trailing paths require an exact match. Each route handler has stack
effect `( request -- response )`; the router calls `send-response` itself.

See `examples/http-server.1z` for a runnable router-based server.

## Serving Static Files

`serve-static: ( host port doc-root -- )` is a one-liner for serving a
directory of files. It normalizes request paths to prevent directory
traversal, falls back to `index.html` for paths ending in `/`, and uses
the MIME-type table in `lib/mimetype.1z` for Content-Type. Files outside
`doc-root` are not reachable.

```
use "net/http" ;

"127.0.0.1" 18080 "./public" serve-static
```

## API Reference

See [`../reference/net/http.md`](../reference/net/http.md) for the full
generated word list, and [`../reference/net/http/router.md`](../reference/net/http/router.md)
for the router surface.

The [next guide](cgi.md) covers running net/http handlers as classical
CGI scripts.

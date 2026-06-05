# CGI

`lib/net/cgi.1z` is a deployment adapter that lets a net/http handler run
as a classical CGI script. The handler shape (`( stream request -- )`),
the `request` value, and the `response` value are the same as under
`lib/net/http.1z`'s `serve`; the only thing that changes is the entry
point. Read [the HTTP guide](http.md) first -- this guide assumes you are
comfortable with the handler signature and `send-response`.

## Handler Shape

The library entry point is `cgi-run: ( handler -- )`. It reads the CGI
environment variables, builds a `request`, constructs a bidirectional
stream over stdin and stdout, calls the handler once with
`( stream request -- )`, and closes the stream on the way out.

```
use "net/cgi" ;
use "net/http" ;

[
  \ stack: stream request
  drop
  "hello, cgi\n" "text/plain; charset=utf-8" ok
  send-response
] cgi-run
```

A handler that throws produces a CGI 500 response on stdout. The stream
is closed unconditionally, whether the handler returns normally or
unwinds with an error.

`request` carries the same wire-derived, socket-derived, and TLS-derived
fields as under HTTP. The CGI side populates them from the standard CGI
environment variables: `REQUEST_METHOD`, `SCRIPT_NAME`, `PATH_INFO`,
`QUERY_STRING`, `SERVER_PROTOCOL`, `REMOTE_ADDR`, `REMOTE_PORT`,
`SERVER_NAME`, `SERVER_PORT`, and the `HTTPS` / `SSL_*` family for TLS
state. `HTTP_*` env vars are reassembled into the headers hash with
canonical lowercased keys. `path>>` is the byte concatenation of
`SCRIPT_NAME` and `PATH_INFO`, matching the URI path the client sent.

## Parsed-CGI Wire Format

`cgi-run` operates in parsed-CGI mode. Around the handler invocation it
binds the `response-status-line-prefix` dynamic variable to `"Status: "`,
so a handler's call to `send-response` emits

```
Status: 200 OK
Content-Type: text/plain; charset=utf-8
Content-Length: 11

hello, cgi
```

instead of an `HTTP/1.1` status line. The web server consumes the
`Status:` line, prefixes the real `HTTP/1.1 <code> <reason>\r\n`, adds
its own transport-level headers (`Date`, `Server`, `Connection`,
transfer encoding), and forwards the rest to the client. The handler
itself does not know which transport it is on; the same word runs
unchanged under `serve` and under `cgi-run`.

## Web-Server Configuration

A CGI deployment needs three things: an executable on disk that the web
server can run, a URL path that maps to that executable, and the right
environment for the script. The two configurations below run
`examples/cgi-bin/page-counter.1z` end-to-end. Either an AOT-compiled
binary or an executable script with a shebang works; the examples assume
the script form.

The first line of each example script should be a shebang naming the
interpreter, and the file must be executable:

```
#!/usr/bin/env -S 1z

use "net/cgi" ;
...
```

```
chmod +x page-counter.1z
```

### Apache (`mod_cgi` or `mod_cgid`)

```apache
ScriptAlias /cgi-bin/ "/srv/onez-cgi/"

<Directory "/srv/onez-cgi/">
    Options +ExecCGI
    AddHandler cgi-script .1z
    Require all granted
    SetEnv PAGE_COUNTER_FILE /var/lib/onez-cgi/page-counter.dat
</Directory>
```

Drop `page-counter.1z` into `/srv/onez-cgi/`, ensure it is executable
and that the shebang resolves to the `1z` interpreter on the server's
`PATH`, and the script is reachable at `/cgi-bin/page-counter.1z`.

### nginx with `fcgiwrap`

nginx ships no native CGI executor; the conventional bridge is
`fcgiwrap`, which speaks FastCGI on a Unix socket and execs the CGI
binary for each request:

```nginx
location ~ \.1z$ {
    fastcgi_pass unix:/run/fcgiwrap.socket;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    fastcgi_param PAGE_COUNTER_FILE /var/lib/onez-cgi/page-counter.dat;
    include fastcgi_params;
}
```

`fastcgi_params` from the nginx distribution populates the standard CGI
env vars (`REQUEST_METHOD`, `QUERY_STRING`, `REMOTE_ADDR`, the `HTTP_*`
header lift, and the rest); the explicit `fastcgi_param` lines layer on
per-script configuration. `fcgiwrap` itself is started out of band, by
the operator's init system, and is typically the same user that owns
the state files below.

## State Files and Permissions

The CGI process runs as the web server's user (`www-data`, `apache`,
`_www`, `http`, depending on distribution). Any path the script writes
to -- the page counter's `PAGE_COUNTER_FILE`, the guestbook's
`GUESTBOOK_DB`, an application log, an upload destination -- must be
writable by that user. The shipped examples each default to a relative
path in the working directory, which is usually the cgi-bin directory
itself; in production, point the env var at a path under
`/var/lib/onez-cgi/` (or your distribution's equivalent) that is owned
by the web server user and not served as static content.

The page-counter's open-read-modify-write idiom is safe under low
concurrency. At meaningful request rates the lack of atomic increment
becomes a hazard; the guestbook reaches for SQLite specifically because
its commit gives the right serialization for the dynamic-content case.
See the top-of-file doc-comments in `examples/cgi-bin/page-counter.1z`
and `examples/cgi-bin/guestbook.1z` for the per-example reasoning.

## API Reference

See [`../reference/net/cgi.md`](../reference/net/cgi.md) for the
generated word list.

The [next guide](ffi.md) covers calling C libraries from 1z.

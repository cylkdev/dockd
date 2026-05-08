# Docker HTTP Upgrade Tunneling and Interactive Exec Session Flow

The Docker daemon exposes an HTTP API over a Unix socket at `/var/run/docker.sock`.
Simple Docker operations like creating containers or pulling images work with normal
HTTP request/response behavior, so regular HTTP libraries can handle them without
problems.

Interactive container execution is different. When you start or attach to a running
exec session using endpoints like `/exec/{id}/start`, Docker replies with `101 Switching Protocols`.
That response means HTTP is finished and the underlying socket connection is now
handed directly to the client for raw two-way communication.

Most HTTP libraries are designed around the assumption that every request ends with
a complete HTTP response. Because of that, when they encounter a `101 Switching Protocols`
response they usually close the connection, discard the socket, or treat it as an
error. They do not expose the raw socket back to the caller because their architecture
assumes the HTTP lifecycle is complete.

`Sorrel` solves this by treating HTTP upgrades as a first-class feature through a
dedicated `tunnel/5` function. Instead of stopping after the upgrade response, 
it:
  
1. Sends the HTTP request normally
2. Reads and validates the `101 Switching Protocols` response
3. Preserves any bytes already buffered after the HTTP headers
4. Returns ownership of the raw socket back to the caller

After the upgrade succeeds, the connection is no longer considered HTTP. The caller
directly reads and writes raw bytes over the socket. Writing sends data into the
container's stdin, while reading receives stdout and stderr from the running process.

Docker introduces another complication when a container is started without a PTY
(`tty: false`). In that mode, stdout and stderr are multiplexed together over the
same socket using Docker-specific 8-byte frame headers. Each frame contains metadata
describing which stream the payload belongs to and how large the payload is.
`Docker.Engine.Frame` is responsible for decoding these frames and reconstructing
clean stdout and stderr streams for the caller.

When a PTY is enabled (`tty: true`), Docker skips this framing system entirely and
instead sends a single raw byte stream directly over the socket. `Docker.Engine.Streaming.Session`
handles the differences between framed and raw stream behavior using the `tty` flag.

The full execution flow in this repository works like this:

`Docker.exec_session/3`
1. creates an exec instance in Docker and receives an `exec_id`

`Sorrel.tunnel/5`
1. sends the HTTP request to `/exec/{exec_id}/start`
2. reads the `101 Switching Protocols` response
3. returns the upgraded raw socket and any leftover buffered bytes

`Docker.Engine.Streaming.Session.from_upgrade/3`
1. wraps the socket and stream state into a session struct

`Session.recv/3`
1. reads bytes from the socket
2. demultiplexes Docker frames if necessary
3. returns clean stdout lines or chunks

`Session.close/1`
1. closes the raw socket connection cleanly

The fundamental limitation with libraries like `Req` is that they do not provide
a tunneling or upgrade primitive. Their design stops at the end of the HTTP
response lifecycle. `Sorrel` was intentionally designed to support protocol
upgrades where HTTP transitions into long-lived raw socket communication.
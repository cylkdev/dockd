# Understanding Dockd

This guide explains how dockd works from the ground up. It assumes no prior knowledge of
Docker's internals, HTTP protocol details, or the libraries involved. By the end you will
understand exactly what happens - at the network and protocol level - when you call
`Dockd.prepare/2`, why sending commands into a running container over code is harder than
it sounds, and precisely how the `:sorrel` library makes it possible.

---

## What dockd is for

Dockd is a library that spins up short-lived Docker containers, runs setup commands inside
them, and gives you back a handle you can use to interact with them programmatically.

The one-sentence version: **dockd turns a Docker image into a ready-to-use instance,
entirely from code.**

Let's take a look at an example:

```elixir
{:ok, instance} = Dockd.run("node:20-slim",
  steps: [
    %{label: "install deps", cmd: ["npm", "install"]},
    %{label: "seed database", cmd: ["node", "seed.js"]}
  ]
)

# The container is now running and both setup steps have completed.
instance.shell_command
#=> "docker exec -it dockd-1 /bin/sh"
```

When `prepare/2` returns, you have a live container with your setup already applied.
`instance.shell_command` is the string a human can paste into a terminal to drop into the
container interactively. The same instance can also be driven entirely from code using
`Dockd.Claude`.

---

## The prepare pipeline

`Dockd.prepare/2` does not do one thing - it runs a sequential pipeline of phases. Each phase
is labelled so that when something goes wrong you know exactly where it failed.

```
Input: image name + options
         │
         ▼
  ┌─────────────┐
  │  :validate  │  Check options for unknown keys, invalid values
  └──────┬──────┘
         │
         ▼
  ┌─────────────────────────┐
  │  :build  or  :pull      │  Build image from Dockerfile,
  │  (one or the other)     │  OR pull image from a registry
  └──────────┬──────────────┘
             │
             ▼
      ┌─────────────┐
      │   :create   │  Create a Docker container from the image
      └──────┬──────┘
             │
             ▼
      ┌─────────────┐
      │   :start    │  Start the container
      └──────┬──────┘
             │
             ▼
      ┌─────────────┐
      │   :fetch    │  Clone git repos from the host into the container
      └──────┬──────┘
             │
             ▼
      ┌─────────────┐
      │   :copy     │  Copy host files/directories into the container
      └──────┬──────┘
             │
             ▼
      ┌─────────────┐
      │   :setup    │  Run the user-supplied setup steps inside
      │             │  the container, in order
      └──────┬──────┘
             │
             ▼
   {:ok, %Dockd.Instance{}}
```

If any phase fails, the pipeline stops immediately and returns
`{:error, %Dockd.Error{phase: :create, ...}}`
(or whichever phase failed). If a container was created before the failure,
the error struct carries a partial `Dockd.Instance` with the container ID,
so you can call `Dockd.destroy/1` to clean it up.

### The Instance struct

The `Dockd.Instance` struct that `prepare/2` returns is the state snapshot
of your instance at the moment it was ready:

```elixir
%Dockd.Instance{
  container_id:   "a3f9c2d...",         # Docker's internal container ID
  container_name: "dockd-1",            # Human-readable name
  image:          "node:20-slim",       # The image it was started from
  shell:          "/bin/sh",            # Binary to exec for interactive attach
  shell_command:  "docker exec -it dockd-1 /bin/sh",  # Ready-to-paste string
  step_results:   [                     # One entry per :steps item, in order
    %Dockd.StepResult{label: "install deps", exit_code: 0, output: "..."},
    %Dockd.StepResult{label: "seed database", exit_code: 0, output: "..."}
  ],
  docker_options: [socket: "/var/run/docker.sock"]  # Connection config
}
```

Think of `Dockd.Instance` as a **receipt** for the container. It records
everything needed to operate on or clean up the container later.

---

## How dockd talks to Docker

Before getting to the interactive part, it helps to understand the communication
channel itself.

Docker runs as a background daemon (`dockerd`) and exposes a **REST API** - a
standard HTTP API. You make HTTP requests to Docker and it responds. Every `docker`
CLI command you have ever run is, under the hood, making HTTP calls to this API.

The unusual part is *where* the API listens. Instead of a port like `localhost:4000`,
Docker by default listens on a **Unix domain socket** at `/var/run/docker.sock`.

A Unix socket is like a TCP socket - you can send and receive bytes over it - but it
lives on the filesystem as a file rather than on a network port. It is faster than
TCP for local communication and does not require any networking setup.

```
Your code                            Docker daemon
    │                                      │
    │  HTTP request                        │
    │  (over /var/run/docker.sock)         │
    │──────────────────────────────────►   │
    │                                      │
    │           HTTP response              │
    │   ◄──────────────────────────────── ─│
    │                                      │
```

Dockd uses the `:sorrel` library to make these HTTP calls. Sorrel knows how to speak
HTTP over Unix sockets - you give it the socket path and it handles the rest.

Let's take a look at an example of what happens on the wire when dockd creates a container:

```
dockd sends:
  POST /v1.43/containers/create HTTP/1.1
  Host: localhost
  Content-Type: application/json

  {"Image": "node:20-slim", "Cmd": ["/bin/sh"]}


Docker responds:
  HTTP/1.1 201 Created
  Content-Type: application/json

  {"Id": "a3f9c2d8b1...", "Warnings": []}
```

This is entirely ordinary HTTP. The `:sorrel` library's `request/5` function handles
calls like this throughout the pipeline - creating containers, starting them, running
exec commands, copying files.

---

## The hard problem: running commands inside a container

The pipeline phases above are all ordinary HTTP calls. Create a container: one request,
one response. Start it: one request, one response. Copy a file in: one request, one
response.

But one thing is genuinely different:

**Running a command inside the container and reading back its output as it arrives**.

This is what `Dockd.Claude` needs - it runs `claude --print` inside the container and
streams the JSON output back line by line, in real time.

Why is this hard? Because HTTP is a **request/response** protocol. You send one request,
you get one response, the exchange is over. You cannot have an ongoing two-way
conversation using normal HTTP.

```
Normal HTTP:

  Your code        Docker daemon
      │                  │
      │─── request ────► │
      │                  │
      │ ◄─── response ───│
      │                  │
      │   (done, socket  │
      │    is closed)    │
```

Running a command interactively requires something completely different. You need to:

1. Send bytes into the container's stdin (the command's input)
2. Read bytes from its stdout and stderr as they are produced
3. Keep the channel open until the process finishes

That is a **two-way stream**, not a request/response exchange:

```
Interactive exec:

  Your code        Docker daemon        Container process
      │                  │                      │
      │─── open exec ──► │ ─── start proc ────► │
      │                  │                      │
      │ ◄─────── stdout bytes ─────────────── ──│
      │ ◄─────── stdout bytes ──────────────────│
      │─── stdin bytes ──► │ ──────────────────►│
      │ ◄─────── stderr bytes ─────────────── ──│
      │                  │                      │
      │ ◄─────── (process exits, channel closes)│
```

---

## The 101 Switching Protocols upgrade

HTTP has a mechanism for exactly this situation: **connection upgrades**.
The client sends a request with a special `Connection: Upgrade` header,
and if the server agrees, it responds with status `101 Switching Protocols`.
After that response, the HTTP protocol ends on that connection - both sides
have agreed to speak something else over the same socket from that point on.

WebSockets use this mechanism. Docker's exec and attach APIs use it too.

Here is what the exchange looks like at the wire level when dockd opens an
exec instance:

```
Step 1 - dockd sends a normal HTTP POST:

  POST /v1.43/exec/e7d2.../start HTTP/1.1
  Host: localhost
  Content-Type: application/json
  Connection: Upgrade
  Upgrade: tcp

  {"Detach": false, "Tty": false}

---

Step 2 - Docker agrees and responds with 101:

  HTTP/1.1 101 UPGRADED
  Content-Type: application/vnd.docker.raw-stream
  Connection: Upgrade
  Upgrade: tcp

  ↑ HTTP ends here. The socket is now a raw byte pipe.

---

Step 3 - bytes flow freely in both directions:

  dockd  ──── stdin bytes ────────────►  container process
  dockd  ◄─── stdout bytes ────────────  container process
  dockd  ◄─── stderr bytes ────────────  container process
         (until process exits)
```

The critical moment is after step 2. The socket is no longer speaking HTTP.
It has become a raw bidirectional pipe. Dockd can now write bytes into the
container's stdin and read bytes from its stdout and stderr, indefinitely,
until the process exits and the connection closes.

---

## Why most HTTP libraries cannot do this

Most HTTP client libraries such as `finch` are designed entirely around the
request/response model. When they receive a `101` response they do not know
what to do with it. They typically close the connection or return an error.
Crucially, they never give the caller access to the raw socket after the
upgrade - because their entire design assumes that HTTP ends with a complete
response.

```
What req does with a 101 response:

  Your code (req)  Docker daemon
       │                │
       │── request ───► │
       │                │
       │  ◄── 101 ──────│
       │                │
       │  (close / error - socket is gone, caller has nothing)
```

```
What sorrel does with a 101 response:

  Your code (sorrel)                                    Docker daemon
       │                                                      │
       │─────── request ────────────────────────────────────► │
       │                                                      │
       │  ◄──────────────────────────── 101 ──────────────────│
       │                                                      │
       │  (strips HTTP headers, hands caller the raw socket)  │
       │                                                      │
       │  caller now owns the socket:                         │
       │                                                      │
       │── bytes ───────────────────────────────────────────► │
       │ ◄── bytes ───────────────────────────────────────────│
       │ ◄── bytes ───────────────────────────────────────────│
       │── bytes ───────────────────────────────────────────► │
       │              (continues until process exits)
```

Sorrel has a dedicated function for this: `tunnel/5`. Its entire job
is to perform the upgrade handshake and return the raw socket. The caller
owns the socket from that point on and is responsible for closing it when done.

```elixir
# Inside sorrel (simplified):
{:ok, socket, leftover} = Sorrel.tunnel(
  endpoint,              # unix:///var/run/docker.sock
  :post,
  "/v1.43/exec/e7d2.../start",
  ~s({"Detach": false, "Tty": false})
)

# `socket` is now a raw TCP/Unix socket.
# `leftover` contains any bytes that arrived right after the 101 headers
# before we handed the socket back - these need to be processed first.
```

---

## Docker's frame multiplexing

There is one more wrinkle. When a container runs without a PTY, Docker does
not send stdout and stderr as a single merged stream. It **multiplexes** them:
it wraps each chunk of output in an 8-byte header that identifies which
stream the chunk belongs to and how long the chunk is.

### What a PTY is

A PTY (pseudo-terminal, sometimes called a TTY) is a fake terminal the operating
system creates. When you open a terminal application, run `ssh`, or use `tmux`,
each of those instances is backed by a PTY. It creates the illusion of a real
terminal - line editing, Ctrl-C, colour codes, and so on all work because the
PTY kernel driver processes them.

When Docker starts a container *with* a PTY (the `-t` flag in `docker run -it ...`),
it allocates a PTY and wires it to the container's process. The kernel merges
stdout and stderr into one single stream, exactly as they appear on a real
terminal. Docker forwards that merged stream to the caller unchanged.

When Docker starts a container *without* a PTY - which is the default when
talking to the Engine API directly from code - stdout and stderr stay separate.
Since Docker must deliver both over the same single socket, it wraps each chunk
in a frame header to tell them apart.

```
With PTY (docker run -it):

  Container process
      ├─ stdout ─┐
      └─ stderr ─┤  kernel merges them in the PTY driver
                 ▼
       single raw byte stream ──────────────────────► caller


Without PTY (API default, used by dockd):

  Container process
      ├─ stdout ──────┐
      └─ stderr ──────┤  Docker keeps them separate,
                      │  wraps each chunk in a frame header
                      ▼
   [header][stdout chunk][header][stderr chunk][header][stdout chunk]...
                                                               ──────────► caller
                                                                 (must demultiplex)
```

### The 8-byte frame header format

Every chunk of output is preceded by an 8-byte header:

```
┌──────────┬───────────────┬──────────────┬──────────────────────────┐
│  byte 0  │  bytes 1–3    │  bytes 4–7   │  bytes 8 to 8+N-1        │
│          │               │              │                          │
│  stream  │   reserved    │ payload size │       payload            │
│  type    │  (3 padding   │  (32-bit     │  (N bytes of actual      │
│          │   bytes,      │   big-endian │   stdout or stderr       │
│  1=stdout│   ignored)    │   integer)   │   output)                │
│  2=stderr│               │              │                          │
└──────────┴───────────────┴──────────────┴──────────────────────────┘
```

Let's take a look at an example. Imagine the container process prints `hello\n` to stdout.
On the wire, after the 101 upgrade, dockd receives these 14 bytes:

```
Raw bytes received (hexadecimal):
  01 00 00 00 00 00 00 06 68 65 6c 6c 6f 0a

Decoded:
  01           = stream type 1 = stdout  ← "this is a stdout chunk"
  00 00 00     = reserved, ignored
  00 00 00 06  = payload length = 6 bytes
  68 65 6c 6c 6f 0a = ASCII for "hello\n"
```

After reading byte 0 (`01` = stdout) and bytes 4–7 (`00 00 00 06` = 6 bytes follow),
the reader knows exactly where this frame ends and the next header begins.
The `Docker.Engine.Frame` module in this codebase handles stripping these headers
and routing payload bytes to the correct buffer (stdout vs stderr).

---

## The streaming instance struct

`Docker.Engine.Streaming.Session` is the struct that wraps the raw socket after
the 101 upgrade and manages all the bookkeeping for reading from it cleanly.

```
%Docker.Engine.Streaming.Session{
  socket:        <raw socket from Sorrel.tunnel>,
  tty:           false,  ← no PTY → Docker frame headers need stripping
  buffer:        "",     ← stdout bytes received but not yet returned
  stderr_buffer: "",     ← stderr bytes received but not yet returned
  frame_buffer:  "",     ← partial frame header, waiting for more bytes
  closed:        false
}
```

When your code calls `Session.recv(instance, {:until, "\n"}, timeout: 120_000)`,
here is what happens internally:

```
Session.recv(instance, {:until, "\n"}, ...)
  │
  ├── check: does instance.buffer already contain "\n"?
  │     └── no → read more bytes from socket
  │
  ├── receive raw bytes from socket (e.g. the 14 bytes above)
  │
  ├── pass through Docker.Engine.Frame.demux/1:
  │     ├── reads byte 0: stream type = 1 (stdout)
  │     ├── reads bytes 4–7: payload length = 6
  │     ├── reads 6 payload bytes: "hello\n"
  │     └── returns {stdout: "hello\n", stderr: "", leftover: ""}
  │
  ├── append "hello\n" to instance.buffer
  │
  ├── check: does buffer contain "\n"? YES
  │
  ├── split at "\n": return "hello\n", keep "" in buffer
  │
  └── returns {:ok, "hello\n", updated_instance}
```

This loop repeats - reading, demuxing, buffering, checking for the delimiter -
until the delimiter appears or the timeout fires.

---

## How Dockd.Claude uses all of this

`Dockd.Claude` is the module that runs `claude --print` inside a prepared instance
and returns either a single JSON result (`ask/3`) or a live stream of JSON events
(`ask_stream/3`).

Here is the complete chain for `ask_stream/3`, traced from your API call down to
the raw socket and back:

```
Your code
  │
  │  {:ok, stream} = Dockd.Claude.ask_stream(instance, "what is 2+2")
  │
  ▼

Step 1 - build the argv list:
  ["claude", "--print", "--output-format", "stream-json", "--verbose", "what is 2+2"]

Step 2 - register the exec instance with Docker:
  POST /v1.43/containers/{container_id}/exec
  {"Cmd": ["claude", "--print", ...], "AttachStdout": true, "Tty": false}
  ← Docker returns an exec_id

Step 3 - start the exec with a 101 upgrade (Sorrel.tunnel):
  POST /v1.43/exec/{exec_id}/start
  {"Detach": false, "Tty": false}
  ← Docker responds: 101 Switching Protocols
  ← Sorrel returns the raw socket

Step 4 - wrap the socket:
  Docker.Engine.Streaming.Session.from_upgrade(socket, leftover, tty: false)
  ← instance = %Session{socket: ..., tty: false, buffer: "", ...}

Step 5 - build an Elixir Stream (lazy - nothing is read yet):
  Stream.resource(
    fn -> {instance, ""}                         end,  # initial state
    fn state -> read_next_json_line(state)       end,  # pull next event
    fn {s, _} -> Session.close(s)               end   # cleanup on halt
  )

Step 6 - each time your code pulls from the stream:
  Session.recv(instance, {:until, "\n"}, timeout: 120_000)
    ├── reads bytes from socket
    ├── strips Docker frame headers
    ├── buffers until "\n" appears
    └── returns one complete line

  JSON.decode!("{\"type\":\"assistant\",\"message\":{...}}")
    └── returns %{"type" => "assistant", "message" => {...}}

Step 7 - when the claude process exits:
  Session.recv returns {:error, :closed, instance}
    └── stream halts
    └── Session.close(instance) releases the socket
```

---

## The complete layer diagram

Here is every layer involved, from your code to the bytes on the socket:

```
┌─────────────────────────────────────────────────────────────┐
│  Your code                                                  │
│                                                             │
│  Dockd.prepare/2     Dockd.Claude.ask_stream/3              │
└────────────┬──────────────────┬─────────────────────────────┘
             │                  │
             ▼                  ▼
┌─────────────────────────────────────────────────────────────┐
│  Dockd  (this library)                                      │
│                                                             │
│  Pipeline phases           Dockd.Claude                     │
│  (validate, create, etc.)  (builds argv, wraps stream)      │
└────────────┬──────────────────┬─────────────────────────────┘
             │                  │
             ▼                  ▼
┌─────────────────────────────────────────────────────────────┐
│  Docker  (../docker library)                                │
│                                                             │
│  Docker.exec_run_with_status   Docker.exec_instance          │
│  Docker.create_container       Docker.Engine.Streaming      │
│  Docker.start_container        Docker.Engine.Frame          │
│  Docker.Engine.Client          Docker.Engine.Streaming      │
│                                .Session                     │
└────────────┬──────────────────┬─────────────────────────────┘
             │                  │
   ordinary  │          101     │  upgrade
   request/  │          tunnel  │  (raw socket)
   response  │                  │
             ▼                  ▼
┌─────────────────────────────────────────────────────────────┐
│  Sorrel  (HTTP client library)                              │
│                                                             │
│  Sorrel.request/5          Sorrel.tunnel/5                  │
│  (one request, one         (101 upgrade → raw socket        │
│   response - used for       handed back to caller)          │
│   create, start, copy,                                      │
│   exec_create, etc.)                                        │
└────────────┬──────────────────┬─────────────────────────────┘
             │                  │
             ▼                  ▼
┌─────────────────────────────────────────────────────────────┐
│  /var/run/docker.sock  (Unix domain socket)                 │
└─────────────────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────┐
│  Docker daemon (dockerd)                                    │
└─────────────────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────┐
│  Container process                                          │
│  (e.g. "claude --print --output-format stream-json ...")    │
└─────────────────────────────────────────────────────────────┘
```

---

## Summary

The reason interactive exec - sending a command into a container and streaming
back the output does not typically work with http libraries is that standard
HTTP libraries treat the Docker `101 Switching Protocols` response as an error
or a dead end. They never expose the raw socket to the caller.

Sorrel was built with `tunnel/5` as a first-class primitive. It performs the
upgrade handshake and returns the raw socket. The rest of the stack - Docker's
frame demultiplexing, buffered delimiter reads, and the Elixir lazy stream - is
built on top of that socket handle.

Without `tunnel/5`, there is no two-way pipe into the container, and none of
the interactive or streaming functionality in dockd works. It is the single
capability that makes everything else possible.

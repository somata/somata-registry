# somata-registry

The Registry is a core service for registering and looking up services by name. Every new Service sends a registry entry (describing its name, hostname, port, protocol), which a Client can then look up to create a Connection.

## Usage

A single registry should be running [running](#running) on each machine using Somata. By default the registry binds to `127.0.0.1:8420`, and by default every Service and Client will connect to the same.

```bash
$ somata-registry
[Registry] Bound to 127.0.0.1:8420
```

Keep it running in the background with your process manager of choice, e.g. [pm2]():

```bash
$ pm2 start somata-registry
```

### Options

Using the `--host`, `--port`, and `--proto` flags you can change where the registry binds:

```bash
$ somata-registry --port 48822
[Registry] Bound to 0.0.0.0:48822
```

### Joining

A registry can "join" to another registry to share registered service information. Clients can then ask their local registry for remotely registered services.

```bash
$ somata-registry --join 192.168.0.44
[Registry] Bound to 0.0.0.0:8420
[Registry] Joined with 192.168.0.44:8420
```

Joining is more bandwidth-efficient and fault-tolerant than tunneling, as clients make direct connections to the remote services. However this only really works on trusted internal networks where machines are directly accessible via multiple ports (which services are bound to).

### Tunneling

A registry can "tunnel" to another registry to share service info while also tunneling all messages through the same connection. A tunnel goes from a "local" machine to a "remote" machine

A tunnel uses a single local &rarr; remote connection, so Clients don't need access to every port a Service is on. The local machine only makes outbound connections, while the remote one needs to be accessible by the registry port.

## Installation

Somata depends on ZeroMQ:

```sh
$ sudo apt-get install libzmq-dev
```

Install the NPM module globally:

```sh
$ sudo npm install -g somata-registry
```
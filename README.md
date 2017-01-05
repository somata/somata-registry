# somata-registry

The Registry is a core Somata service used to register and look up other services by name. Every new Service sends a registry entry (describing itself as `{name, hostname, port, protocol}`). When a Client tries to connect to a Service it looks up available services by name.

## Installation

Somata requires the [Node.js ZeroMQ library](https://github.com/JustinTulloss/zeromq.node), which requires [ZeroMQ](http://zeromq.org/) - install with your system package manager:

```sh
$ sudo apt-get install libzmq-dev
```

Then install the registry globally with NPM:

```sh
$ sudo npm install -g somata-registry
```

## Usage

Each machine running Somata services should also be running a registry. By default the registry binds to `127.0.0.1:8420`.

```bash
$ somata-registry
[Registry] Bound to 127.0.0.1:8420
```

Keep it running in the background with your process manager of choice, e.g. [pm2](https://github.com/Unitech/pm2):

```bash
$ pm2 start somata-registry
```

### Options

Using the `--host`, `--port`, and `--proto` flags you can change where the registry binds:

```bash
$ somata-registry --host 0.0.0.0 --port 48822
[Registry] Bound to 0.0.0.0:48822
```


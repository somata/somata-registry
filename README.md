# Somata Registry

The Registry is a core [Somata](https://github.com/somata) Service used to register and look up other services by name. Every new Service registers itself with the Registry, describing itself as `{name, host, port, protocol}`. When a Client connects to a Service, it first uses the Registry to look up available services by name.

## Installation

Install globally with NPM. See [Somata installation](https://github.com/somata/somata-node#installation) for dependency information.

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


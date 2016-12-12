somata = require 'somata'
async = require 'async'
minimist = require 'minimist'
{log} = somata
{EventEmitter} = require 'events'

argv = minimist process.argv

DEFAULT_REGISTRY_PORT = 8420
DEFAULT_BRIDGE_PORT = 8427
DEFAULT_HEARTBEAT = 5000
BUMP_FACTOR = 1.5 # Wiggle room for heartbeats
BUMP_FACTOR = 1.0 # Wiggle room for heartbeats

VERBOSE = argv.v || argv.verbose || process.env.SOMATA_VERBOSE || false
REGISTRY_BIND_PROTO = argv.proto || process.env.SOMATA_REGISTRY_BIND_PROTO || 'tcp'
REGISTRY_BIND_HOST = argv.host || process.env.SOMATA_REGISTRY_BIND_HOST || '127.0.0.1'
REGISTRY_BIND_PORT = parseInt (argv.port || process.env.SOMATA_REGISTRY_BIND_PORT || DEFAULT_REGISTRY_PORT)
# BRIDGE_BIND_HOST = parseInt (argv['bridge-bind-host'] || process.env.SOMATA_BRIDGE_BIND_PORT || DEFAULT_BRIDGE_PORT)
# BRIDGE_BIND_PORT = parseInt (argv['bridge-bind-port'] || process.env.SOMATA_BRIDGE_BIND_PORT || DEFAULT_BRIDGE_PORT)

# Nested maps of Name -> ID -> Instance
registered = {}
remote_registered = {}

# Map of ID -> Expected heartbeat
heartbeats = {}

# Registration

registerService = (client_id, service_instance, cb) ->
    service_instance.client_id = client_id
    if !service_instance.heartbeat?
        service_instance.heartbeat = DEFAULT_HEARTBEAT
    registered[service_instance.name] ||= {}
    if existing = registered[service_instance.name][service_instance.id]
        log.w '[registerService] Service exists', existing
    registered[service_instance.name][service_instance.id] = service_instance
    heartbeats[client_id] = new Date().getTime() + service_instance.heartbeat * BUMP_FACTOR
    log.s "[Registry.registerService] <#{client_id}> as #{service_instance.id}"
    registry.publish 'register', service_instance
    registry.emit 'register', service_instance
    cb null, service_instance

deregisterService = (service_name, service_id, cb) ->
    log.w "[Registry.deregisterService] #{service_id}"
    if service_instance = registered[service_name]?[service_id]
        delete heartbeats[service_instance.client_id]
        delete registered[service_name][service_id]
        delete registry.binding.known_pings[service_instance.client_id]
        registry.publish 'deregister', service_instance
        registry.emit 'deregister', service_instance
    cb? null, service_id

# Health checking

isHealthy = (service_instance) ->
    if service_instance.heartbeat == 0 then return true
    next_heartbeat = heartbeats[service_instance.client_id]
    is_healthy = next_heartbeat > new Date().getTime()
    if !is_healthy
        log.w "Heartbeat overdue by #{new Date().getTime() - next_heartbeat}" if VERBOSE
        deregisterService service_instance.name, service_instance.id
    return is_healthy

checkServices = ->
    for service_name, service_instances of registered
        for service_id, service_instance of service_instances
            isHealthy service_instance

setInterval checkServices, 500

# Finding services

findServices = (cb) ->
    cb null, registered

getHealthyServiceByName = (service_name) ->
    service_instances = registered[service_name]
    # TODO: Go through to find healthy ones
    for service_id, instance of service_instances
        if isHealthy instance
            return instance
    return null

getRemoteServiceByName = (service_name) ->
    service_instances = remote_registered[service_name]
    # TODO: Go through to find healthy ones
    if service_instances? and Object.keys(service_instances).length
        return service_instances[Object.keys(service_instances)[0]]

getServiceById = (service_id) ->
    service_name = service_id.split('~')[0]
    return registered[service_name]?[service_id]

getServiceByClientId = (client_id) ->
    for service_name, service_instances of registered
        for service_id, instance of service_instances
            if instance.client_id == client_id
                return instance
    return null

getService = (service_name, cb) ->
    if service_instance = getHealthyServiceByName(service_name)
        cb null, service_instance
    else if service_instance = getRemoteServiceByName(service_name)
        cb null, service_instance
    else
        log.w "No healthy instances for #{service_name}"
        cb "No healthy instances for #{service_name}"

# Sharing with other registries

# Heartbeat responses

registry_methods = {
    registerService
    deregisterService
    findServices
    getService
}

registry_options =
    binding_options:
        proto: REGISTRY_BIND_PROTO
        host: REGISTRY_BIND_HOST
        port: REGISTRY_BIND_PORT

class Registry extends somata.Service

    register: ->
        log.i "[Registry] Bound to #{REGISTRY_BIND_HOST}:#{REGISTRY_BIND_PORT}"
        log.d "[Registry.register] Who registers the registry?" if VERBOSE
        @binding.on 'ping', (client_id, message) =>
            @gotPing client_id

    deregister: (cb) ->
        cb()

    handleMethod: (client_id, message) ->

        # Registering a service
        if message.method == 'registerService'
            registerService client_id, message.args..., (err, response) =>
                @sendResponse client_id, message.id, response

        else if message.method == 'registerServices'
            service_instances = message.args[0]
            async.map service_instances, registerService.bind(null, client_id), (err, response) =>
                @sendResponse client_id, message.id, response

        else
            super

    gotPing: (client_id) ->
        if service_instance = getServiceByClientId client_id
            heartbeat_interval = service_instance.heartbeat
            heartbeats[client_id] = new Date().getTime() + heartbeat_interval * BUMP_FACTOR

registry = new Registry 'somata:registry', registry_methods, registry_options

if (bridge_string = argv.t || argv.bridge) and false
    [host, port] = bridge_string.split(':')

    registry.bridge_remote_client = new BridgeRemote {
        registry
        registry_host: host
        registry_port: port || DEFAULT_REGISTRY_PORT
    }

    log.i '[Registry.bridge] ' + bridged


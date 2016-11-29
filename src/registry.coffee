somata = require 'somata'
minimist = require 'minimist'
{log} = somata
{EventEmitter} = require 'events'

argv = minimist process.argv

VERBOSE = argv.v || argv.verbose || process.env.SOMATA_VERBOSE || false
DEFAULT_REGISTRY_PORT = 8420
DEFAULT_HEARTBEAT = 5000
REGISTRY_BIND_PROTO = argv.proto || process.env.SOMATA_REGISTRY_BIND_PROTO || 'tcp'
REGISTRY_BIND_HOST = argv.h || argv.host || process.env.SOMATA_REGISTRY_BIND_HOST || '127.0.0.1'
REGISTRY_BIND_PORT = parseInt (argv.p || argv.port || process.env.SOMATA_REGISTRY_BIND_PORT || DEFAULT_REGISTRY_PORT)
BUMP_FACTOR = 1.5 # Wiggle room for heartbeats

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
    registered[service_instance.name][service_instance.id] = service_instance
    heartbeats[client_id] = new Date().getTime() + service_instance.heartbeat * 1.5
    log.s "[Registry.registerSErvice] <#{client_id}> as #{service_instance.id}"
    registry.publish 'register', service_instance
    registry.emit 'register', service_instance
    cb null, service_instance

deregisterService = (service_name, service_id, cb) ->
    log.w "[Registry.deregisterService] #{service_id}"
    if service_instance = registered[service_name]?[service_id]
        delete heartbeats[service_instance.client_id]
        delete registered[service_name][service_id]
        delete registry.known_pings[service_instance.client_id]
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

setInterval checkServices, 2000

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

foundRemoteServices = (remote_registry) -> (err, remote_services) ->
    for service_name, service_instances of remote_services
        for service_id, service_instance of service_instances
            registeredRemoteService(remote_registry)(service_instance)

registeredRemoteService = (remote_registry) -> (service) ->
    if service.host == '0.0.0.0'
        service.host = remote_registry.host
    else if remote_registry.is_tunnel
        service.host = REGISTRY_BIND_HOST
        service.port = REGISTRY_BIND_PORT
    service.registry = remote_registry
    remote_registered[service.name] ||= {}
    remote_registered[service.name][service.id] = service

deregisteredRemoteService = (remote_registry) -> (service) ->
    delete remote_registered[service.name][service.id]
    registry.publish 'deregister', service

tunnel_remote_client = null

join = (remote_registry, cb) ->
    tunnel_remote_client = new somata.Client {
        registry_host: remote_registry.host
        registry_port: remote_registry.port || DEFAULT_REGISTRY_PORT
    }
    tunnel_remote_client.registry_connection.on 'connect', ->
        tunnel_remote_client.remote 'registry', 'findServices', foundRemoteServices(remote_registry)
    tunnel_remote_client.registry_connection.on 'failure', ->
        Object.keys(remote_registered).map (service_name) ->
            remote_instances = remote_registered[service_name]
            Object.keys(remote_instances).map (service_id) ->
                service = remote_instances[service_id]
                deregisteredRemoteService(remote_registry)(service)
    tunnel_remote_client.subscribe 'registry', 'register', registeredRemoteService(remote_registry)
    tunnel_remote_client.subscribe 'registry', 'deregister', deregisteredRemoteService(remote_registry)
    if cb? then cb null, "Joined to #{remote_registry.host}:#{remote_registry.port}"
    return tunnel_remote_client

# Tunnel

tunnel = (remote_registry, cb) ->
    remote_registry.is_tunnel = true
    join(remote_registry, cb)

class TunnelLocal extends somata.Client
    constructor: (options={}) ->
        Object.assign @, options

        @events = new EventEmitter

        # Keep track of subscriptions
        # subscription_id -> {name, instance, connection}
        @service_subscriptions = {}

        # Keep track of existing connections by service name
        @service_connections = {}

        # Deregister when quit
        # emitters.exit.onExit (cb) =>
        #     log.w 'Unsubscribing remote listeners...'
        #     @unsubscribeAll()
        #     cb()
        registry.on 'deregister', (service_instance) =>
            @deregistered(service_instance)
        registry.on 'register', (service_instance) =>
            # @registered(service_instance)

        return @

TunnelLocal::getServiceInstance = (service_name, cb) ->
    if service_name == 'registry'
        cb null, {host: "localhost", port: REGISTRY_BIND_PORT, name: 'tunnel'}
    else
        getService service_name, (err, got) ->
            cb err, got

# Heartbeat responses

registry_methods = {
    registerService
    deregisterService
    findServices
    getService
    join
    tunnel
}

registry_options =
    rpc_options:
        proto: REGISTRY_BIND_PROTO
        host: REGISTRY_BIND_HOST
        port: REGISTRY_BIND_PORT

class Registry extends somata.Service

    register: ->
        log.i "[Registry] Bound to #{REGISTRY_BIND_HOST}:#{REGISTRY_BIND_PORT}"
        log.d "[Registry.register] Who registers the registry?" if VERBOSE

    deregister: (cb) ->
        cb()

    handleMethod: (client_id, message) ->

        # Intercepted from local clients and forwarded to remote tunnel
        if message.service != 'registry'
            tunnel_remote_client.registry_connection.sendMethod null, 'forwardMethod', [message], (err, response) =>
                @sendResponse client_id, message.id, response

        # Incoming forwarded methods for remote end of tunnel
        else if message.method == 'forwardMethod'
            tunnel_local_client.remote message.service, message.method, message.args..., (err, response) ->
                @sendResponse client_id, message.id, response

        # Registering a service
        else if message.method == 'registerService'
            registerService client_id, message.args..., (err, response) =>
                @sendResponse client_id, message.id, response

        else
            super

    tunneled_subscriptions: {}

    handleSubscribe: (client_id, message) ->

        # Intercepted from local clients and forwarded to remote tunnel
        if message.service? and message.service != 'registry'
            tunnel_remote_client._subscribe message.id, 'registry', 'forwardSubscribe', message, (response) =>
                @sendEvent client_id, message.id, response

        # Incoming forwarded subscriptions for remote end of tunnel
        else if message.type == 'forwardSubscribe'
            original_message = message.args[0]
            if @tunneled_subscriptions[original_message.id]
                log.w '[handleSubscribe local] Subscribe already exists', original_message.id if VERBOSE
            else
                log.s '[handleSubscribe local] Creating subscribe for', original_message.id if VERBOSE
                tunnel_local_client._subscribe original_message.id, original_message.service, original_message.type, original_message.args..., (event) =>
                    @sendEvent client_id, original_message.id, event
                @tunneled_subscriptions[original_message.id] = true

        # Regular subscription
        else
            super

    handleUnsubscribe: (client_id, message) ->
        if message.service? and message.service != 'registry'
            tunnel_remote_client.unsubscribe message.id
        else if @tunneled_subscriptions[message.id]
            delete @tunneled_subscriptions[message.id]
            tunnel_local_client.unsubscribe message.id
        else
            super

    gotPing: (client_id) ->
        if service_instance = getServiceByClientId client_id
            heartbeat_interval = service_instance.heartbeat
            heartbeats[client_id] = new Date().getTime() + heartbeat_interval * 1.5

if join_string = argv.j || argv.join
    [host, port] = join_string.split(':')
    join {host, port}, (err, joined) ->
        log.i '[Registry.join] ' + joined

if tunnel_string = argv.t || argv.tunnel
    [host, port] = tunnel_string.split(':')
    tunnel {host, port}, (err, tunneled) ->
        log.i '[Registry.tunnel] ' + tunneled

registry = new Registry 'somata:registry', registry_methods, registry_options

tunnel_local_client = new TunnelLocal

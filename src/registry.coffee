somata = require 'somata'
minimist = require 'minimist'
{log} = somata

argv = minimist process.argv

VERBOSE = argv.v || argv.verbose || process.env.SOMATA_VERBOSE || false
REGISTRY_HOST = argv.h || argv.host || process.env.SOMATA_REGISTRY_HOST || '127.0.0.1'
REGISTRY_PORT = argv.p || argv.port || process.env.SOMATA_REGISTRY_PORT || 8420
DEFAULT_HEARTBEAT = 5000
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
    log.s "Registered #{client_id} as #{service_instance.id}"
    registry.publish 'register', service_instance
    cb null, service_instance

deregisterService = (service_name, service_id, cb) ->
    log.w "Deregistering #{service_id}"
    if service_instance = registered[service_name]?[service_id]
        delete heartbeats[service_instance.client_id]
        delete registered[service_name][service_id]
        delete registry.known_pings[service_instance.client_id]
        registry.publish 'deregister', service_instance
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
    service.registry = remote_registry
    remote_registered[service.name] ||= {}
    remote_registered[service.name][service.id] = service

deregisteredRemoteService = (remote_registry) -> (service) ->
    delete remote_registered[service.name][service.id]
    registry.publish 'deregister', service

join = (remote_registry, cb) ->
    join_client = new somata.Client {registry_host: remote_registry.host, registry_port: remote_registry.port}
    join_client.subscribe 'registry', 'register', registeredRemoteService(remote_registry)
    join_client.subscribe 'registry', 'deregister', deregisteredRemoteService(remote_registry)
    join_client.registry_connection.on 'connect', ->
        join_client.remote 'registry', 'findServices', foundRemoteServices(remote_registry)
    cb null, "Joining to #{remote_registry.host}:#{remote_registry.port}..."

if join_string = argv.j || argv.join
    [host, port] = join_string.split(':')
    join {host, port}, (err, joined) ->
        console.log joined

# Heartbeat responses

registry_methods = {
    registerService
    deregisterService
    findServices
    getService
    join
}

registry_options =
    rpc_options:
        host: REGISTRY_HOST
        port: REGISTRY_PORT

class Registry extends somata.Service

    register: ->
        log.d "[Registry.register] Who registers the registry?"

    deregister: (cb) ->
        cb()

    handleMethod: (client_id, message) ->
        if message.method == 'registerService'
            registerService client_id, message.args..., (err, response) =>
                @sendResponse client_id, message.id, response
        else
            super

    gotPing: (client_id) ->
        if service_instance = getServiceByClientId client_id
            heartbeat_interval = service_instance.heartbeat
            heartbeats[client_id] = new Date().getTime() + heartbeat_interval * 1.5

registry = new Registry 'somata:registry', registry_methods, registry_options


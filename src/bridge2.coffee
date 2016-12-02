somata = require 'somata'
minimist = require 'minimist'
{log} = somata
{EventEmitter} = require 'events'

foundRemoteServices = (remote_registry) -> (err, remote_services) ->
    for service_name, service_instances of remote_services
        for service_id, service_instance of service_instances
            registeredRemoteService(remote_registry)(service_instance)

registeredRemoteService = (remote_registry) -> (service) ->
    if service.host == '0.0.0.0'
        service.host = remote_registry.host
    else if remote_registry.is_bridge
        service.host = REGISTRY_BIND_HOST
        service.port = REGISTRY_BIND_PORT
    service.registry = remote_registry
    remote_registered[service.name] ||= {}
    remote_registered[service.name][service.id] = service

deregisteredRemoteService = (remote_registry) -> (service) ->
    delete remote_registered[service.name][service.id]
    registry.publish 'deregister', service

class BridgeLocal extends somata.Client
    handleMethod: (client_id, message) ->

        # Intercepted from local clients and forwarded to remote bridge
        if message.service? and message.service != 'registry'
            @registry.bridge_remote_client.registry_connection.sendMethod null, 'forwardMethod', [message], (err, response) =>
                @sendResponse client_id, message.id, response

    handleSubscribe: (client_id, message) ->

        # Intercepted from local clients and forwarded to remote bridge
        if message.service? and message.service != 'registry'
            console.log '[handleSubscribe] local client -> [local bridge] -> remote bridge'
            @registry.bridge_remote_client._subscribe message.id, 'registry', 'forwardSubscribe', message, (response) =>
                @sendEvent client_id, message.id, response

    handleUnsubscribe: (client_id, message) ->
        if message.service? and message.service != 'registry'
            @registry.bridge_remote_client.unsubscribe message.id

class BridgeRemote extends somata.Client
    constructor: ->
        super

        remote_registry = {
            host: @registry_host
            port: @registry_port
        }

        @registry_connection.on 'connect', =>
            @registry.bridge_remote_client.remote 'registry', 'findServices', foundRemoteServices(remote_registry)

        @registry_connection.on 'failure', ->
            Object.keys(remote_registered).map (service_name) ->
                remote_instances = remote_registered[service_name]
                Object.keys(remote_instances).map (service_id) ->
                    service = remote_instances[service_id]
                    deregisteredRemoteService(remote_registry)(service)

        @subscribe 'registry', 'register', registeredRemoteService(remote_registry)
        @subscribe 'registry', 'deregister', deregisteredRemoteService(remote_registry)

    handleMethod: (client_id, message) ->

        # Incoming forwarded methods for remote end of bridge
        if message.method == 'forwardMethod'
            original_message = message.args[0]
            bridge_local_client.remote original_message.service, original_message.method, original_message.args..., (err, response) =>
                @sendResponse client_id, message.id, response

    bridged_subscriptions: {}

    handleSubscribe: (client_id, message) ->
        # Incoming forwarded subscriptions for remote end of bridge
        if message.type == 'forwardSubscribe'
            console.log '[handleSubscribe] local bridge -> [remote bridge]'
            original_message = message.args[0]
            if @bridged_subscriptions[original_message.id]
                log.w '[handleSubscribe local] Subscribe already exists', original_message.id if VERBOSE
            else
                log.s '[handleSubscribe local] Creating subscribe for', original_message.id if VERBOSE
                bridge_local_client._subscribe original_message.id, original_message.service, original_message.type, original_message.args..., (event) =>
                    @sendEvent client_id, original_message.id, event
                @bridged_subscriptions[original_message.id] = true

    handleUnsubscribe: (client_id, message) ->
        if @bridged_subscriptions[message.id]
            delete @bridged_subscriptions[message.id]
            bridge_local_client.unsubscribe message.id

# Bridge

module.exports = {
    BridgeLocal
    BridgeRemote
}

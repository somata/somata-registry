somata = require 'somata'
minimist = require 'minimist'
{log} = somata

DEFAULT_REGISTRY_PORT = 8420
DEFAULT_BRIDGE_PORT = 8427

argv = minimist process.argv

VERBOSE = parseInt process.env.SOMATA_VERBOSE or 0
LOCAL_REGISTRY = somata.helpers.parseAddress(argv['registry'], 'localhost', DEFAULT_REGISTRY_PORT)
REMOTE_BRIDGE = somata.helpers.parseAddress(argv['bridge'], null, DEFAULT_BRIDGE_PORT)
if !REMOTE_BRIDGE
    console.log 'Usage: bridge-local [remote host]:[port]'
    process.exit()

# Connection to local registry
bridge_local_client = new somata.Client
    registry_host: LOCAL_REGISTRY.host
    registry_port: LOCAL_REGISTRY.port
bridge_local_registry_connection = bridge_local_client.registry_connection

console.log 'bridge_local_client', somata.helpers.summarizeConnection bridge_local_registry_connection

# Connection to remote bridge
bridge_remote_bridge_connection = new somata.Connection REMOTE_BRIDGE
bridge_remote_bridge_connection.id = 'bridge_local_to_remote'

sendForwardMethod = (message, cb) ->
    log.d '[sendForwardMethod]', message
    forward_message = {
        # id: message.id
        kind: 'forward_method'
        service: message.service
        method: message.method
        args: message.args or []
    }
    bridge_remote_bridge_connection.send forward_message, cb

forward_subscriptions = []

sendForwardSubscribe = (message, cb) ->
    log.d '[sendForwardSubscribe]', message
    forward_message = {
        id: message.id
        kind: 'forward_subscribe'
        service: message.service
        type: message.type
        args: message.args or []
    }
    forward_subscription = bridge_remote_bridge_connection.send forward_message, cb
    forward_subscriptions.push forward_subscription

resendForwardSubscribe = (forward_subscription, cb) ->
    log.d '[resendForwardSubscribe]', forward_subscription
    bridge_remote_bridge_connection.send forward_subscription, cb

class BridgeLocalService extends somata.Service
    handleMethod: (client_id, message) ->

        # Intercepted from local clients and forwarded to remote bridge
        if message.service? and message.service != 'registry'
            sendForwardMethod message, (err, response) =>
                @sendResponse client_id, message.id, response
        else
            log.d 'handleMethod normal', client_id, message
            super

    handleSubscribe: (client_id, message) ->

        # Intercepted from local clients and forwarded to remote bridge
        if message.service? and message.service != 'registry'
            sendForwardSubscribe message, (event) =>
                @sendEvent client_id, message.id, event
        else
            log.d 'handleSubscribe normal', client_id, message
            super

    handleUnsubscribe: (client_id, message) ->
        return null

        # TODO
        if message.service? and message.service != 'registry'
            bridge_remote_client.unsubscribe message.id
        else
            log.d 'handleUnsubscribe normal', client_id, message
            super

bridge_local_service = new BridgeLocalService 'bridge-local', null,
    registry_host: LOCAL_REGISTRY.host
    registry_port: LOCAL_REGISTRY.port

mapObj = (obj, fn) ->
    obj_ = {}
    for k, v of obj
        obj_[k] = fn v
    return obj_

values = (obj) ->
    vals = []
    for k, v of obj
        vals.push v
    return vals

flatten = (ls) ->
    fls = []
    for l in ls
        for i in l
            fls.push i
    return fls

flattenServices = (services) ->
    flatten values(services).map values

connectedLocalRegistry = ->
    console.log '[connectedLocalRegistry]'

    # Also get local registry services
    # TODO: Maybe not necessary if local client has registry info already
    bridge_local_client.remote 'registry', 'findServices', (err, local_services) ->
        console.log '[connectedLocalRegistry] got local services'
        # And send to remote registry for remote clients to reverse-connect to (through events)

all_remote_services = null

connectedRemoteBridge = ->
    console.log '[connectedRemoteBridge]'
    # Ask for remote registries
    sendForwardMethod {service: 'registry', method: 'findServices'}, (err, remote_services) ->
        console.log '[connectedRemoteBridge] sent forward method'

        all_remote_services = remote_services

        remote_services = flattenServices(remote_services)
        remote_services.forEach (remote_service) ->
            # Keep track of remote info for sending back

            remote_service.host = 'localhost'
            remote_service.port = bridge_local_service.binding.port
            # remote_service.id += '-bridged~' + bridge_local_service.id

        bridge_local_client.remote 'registry', 'registerServices', remote_services, (err, local_services) ->
            log.d '[connectedRemoteBridge] Registered remote services with local bridge' if VERBOSE

        # Send them back to local registry with modified connection info (to self)
        # for local clients to connect to

    # Subscribe to remote registry events
    register_subscription = new somata.Subscription {service: 'bridge-remote', type: 'register'}
    register_subscription.subscribe(bridge_remote_bridge_connection)
    register_subscription.on 'register', (registered) ->
        bridge_local_client.remote 'registry', 'registerService', registered, null

    deregister_subscription = new somata.Subscription {service: 'bridge-remote', type: 'deregister'}
    deregister_subscription.subscribe(bridge_remote_bridge_connection)
    deregister_subscription.on 'deregister', (deregistered) ->
        bridge_local_client.remote 'registry', 'deregisterService', deregistered.name, deregistered.id, null

reconnectedRemoteBridge = ->
    console.log '[reconnectedRemoteBridge]'
    connectedRemoteBridge()
    for forward_subscription in forward_subscriptions
        resendForwardSubscribe(forward_subscription)

disconnectedRemoteBridge = ->
    log.w '[disconnectedRemoteBridge]'
    service_name = 'announcement'
    service_id = Object.keys(all_remote_services[service_name])[0]
    service = all_remote_services[service_name][service_id]
    bridge_local_service.publish 'deregister', service_name,  service_id
    bridge_local_client.remote 'registry', 'deregisterService', service_name, service_id, (err, deregistered) ->
        log.d '[disconnectedRemoteBridge] Deregistered', err or deregistered

bridge_local_registry_connection.once 'connect', connectedLocalRegistry
bridge_local_registry_connection.on 'reconnect', connectedLocalRegistry

bridge_remote_bridge_connection.once 'connect', connectedRemoteBridge
bridge_remote_bridge_connection.on 'reconnect', reconnectedRemoteBridge
bridge_remote_bridge_connection.on 'timeout', disconnectedRemoteBridge


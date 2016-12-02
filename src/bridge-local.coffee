somata = require 'somata'
minimist = require 'minimist'

DEFAULT_REGISTRY_PORT = 8420
DEFAULT_BRIDGE_PORT = 8427

argv = minimist process.argv

LOCAL_REGISTRY = somata.helpers.parseAddress(argv['registry'], 'localhost', DEFAULT_REGISTRY_PORT)
REMOTE_BRIDGE = somata.helpers.parseAddress(argv['bridge'], null, DEFAULT_BRIDGE_PORT)
if !REMOTE_BRIDGE
    console.log 'Usage: bridge-local [remote host]:[port]'
    process.exit()

# Connection to local registry
bridge_local_client = new somata.Client
    registry_host: LOCAL_REGISTRY.host
    registry_port: LOCAL_REGISTRY.port

console.log 'bridge_local_client', somata.helpers.summarizeConnection bridge_local_client.registry_connection

# Connection to remote bridge
bridge_local_remote_connection = new somata.Connection REMOTE_BRIDGE
bridge_local_remote_connection.id = 'bridge_local_to_remote'

sendForwardMethod = (message, cb) ->
    forward_message = {
        # id: message.id
        kind: 'forward_method'
        service: message.service
        method: message.method
        args: message.args or []
    }
    bridge_local_remote_connection.send forward_message, cb

sendForwardSubscribe = (message, cb) ->
    forward_message = {
        # id: message.id
        kind: 'forward_subscribe'
        service: message.service
        type: message.type
        args: message.args or []
    }
    bridge_local_remote_connection.send forward_message, cb

class BridgeLocalService extends somata.Service
    handleMethod: (client_id, message) ->

        # Intercepted from local clients and forwarded to remote bridge
        if message.service? and message.service != 'registry'
            sendForwardMethod message, (err, response) =>
                @sendResponse client_id, message.id, response
        else
            console.log 'handleMethod normal', client_id, message
            super

    handleSubscribe: (client_id, message) ->

        # Intercepted from local clients and forwarded to remote bridge
        if message.service? and message.service != 'registry'
            sendForwardSubscribe message, (event) =>
                @sendEvent client_id, message.id, event
        else
            console.log 'handleSubscribe normal', client_id, message
            super

    handleUnsubscribe: (client_id, message) ->
        return null

        # TODO
        if message.service? and message.service != 'registry'
            bridge_remote_client.unsubscribe message.id
        else
            console.log 'handleUnsubscribe normal', client_id, message
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

connectedRegistry = ->
    console.log 'on connect'

    # Ask for remote registries
    sendForwardMethod {service: 'registry', method: 'findServices'}, (err, remote_services) ->
        console.log 'sent forward method'

        remote_services = flattenServices(remote_services)
        remote_services.forEach (remote_service) ->
            # Keep track of remote info for sending back

            remote_service.host = 'localhost'
            remote_service.port = bridge_local_service.binding.port
            remote_service.id += '-bridged~' + bridge_local_service.id

        bridge_local_client.remote 'registry', 'registerServices', remote_services, (err, local_services) ->
            console.log 'registered them'
        # Send them back to local registry with modified connection info (to self)
        # for local clients to connect to

    # Also get local registry services
    bridge_local_client.remote 'registry', 'findServices', (err, local_services) ->
        console.log 'got local services'

        # And send to remote registry for remote clients to reverse-connect to (through events)

bridge_local_remote_connection.once 'connect', connectedRegistry
bridge_local_remote_connection.on 'reconnect', connectedRegistry


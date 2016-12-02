somata = require 'somata'
minimist = require 'minimist'

DEFAULT_REGISTRY_PORT = 8420
DEFAULT_BRIDGE_PORT = 8427

argv = minimist process.argv

VERBOSE = true
LOCAL_REGISTRY = somata.helpers.parseAddress(argv['registry'], 'localhost', DEFAULT_REGISTRY_PORT)
REMOTE_BRIDGE = somata.helpers.parseAddress(argv['bridge'], '0.0.0.0', DEFAULT_BRIDGE_PORT)

# Connection to remote registry (which is local to us)
bridge_remote_local_client = new somata.Client
    registry_host: LOCAL_REGISTRY.host
    registry_port: LOCAL_REGISTRY.port

# bridge_remote_local_client.registry_connection.on 'failure', ->
#     console.log 'local registry failure'

#     Object.keys(remote_registered).map (service_name) ->
#         remote_instances = remote_registered[service_name]
#         Object.keys(remote_instances).map (service_id) ->
#             service = remote_instances[service_id]
#             deregisteredRemoteService(remote_registry)(service)

class BridgeRemoteService extends somata.Service
    bindRPC: ->
        super
        @binding.on 'forward_method', @handleForwardMethod.bind(@)
        @binding.on 'forward_subscribe', @handleForwardSubscribe.bind(@)

    bridged_subscriptions: {}

    handleForwardMethod: (client_id, message) ->
        console.log 'forward (local client -> remote service) handleMethod', client_id, message
        bridge_remote_local_client.remote message.service, message.method, message.args..., (err, response) =>
            if err
                @sendError client_id, message.id, err
            else
                @sendResponse client_id, message.id, response

    handleForwardSubscribe: (client_id, message) ->
        console.log 'forward (local client -> remote service) handleSubscribe', client_id, message
        if @bridged_subscriptions[message.id]
            somata.log.w '[handleForwardSubscribe] Subscribe already exists', message.id if VERBOSE
        else
            somata.log.s '[handleForwardSubscribe] Creating subscribe for', message.id if VERBOSE
            bridge_remote_local_client.subscribe message.service, message.type, message.args..., (event) =>
                @sendEvent client_id, message.id, event
            @bridged_subscriptions[message.id] = true

    handleMethod: (client_id, message) ->
        console.log 'reverse (remote client -> local service) handleMethod', client_id, message

    handleSubscribe: (client_id, message) ->
        console.log 'reverse (remote client -> local service) handleSubscribe', client_id, message

# Binding for local bridges to connect to
bridge_remote_service = new BridgeRemoteService 'bridge-remote', null,
    rpc_options: REMOTE_BRIDGE
    registry_host: LOCAL_REGISTRY.host
    registry_port: LOCAL_REGISTRY.port


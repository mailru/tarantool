#!/usr/bin/env tarantool
local SOCKET_DIR = require('fio').cwd()
local QUORUM = tonumber(arg[1])
local TIMEOUT = arg[2] and tonumber(arg[2]) or 0.1
local CONNECT_TIMEOUT = arg[3] and tonumber(arg[3]) or 10

function nonexistent_uri(id)
--     return 'localhost:'..(1000 + id)
    return SOCKET_DIR .. '/replica_quorum' .. id .. '.sock'
end

box.cfg{
    work_dir = os.getenv('TARANTOOL_WORKDIR'),
    listen = os.getenv('TARANTOOL_LISTEN'),
    replication_timeout = TIMEOUT,
    replication_connect_timeout = CONNECT_TIMEOUT,
    replication_connect_quorum = QUORUM,
    replication = {os.getenv('TARANTOOL_LISTEN'),
                   nonexistent_uri(1),
                   nonexistent_uri(2)}
}
box.once("bootstrap", function()
    box.schema.user.grant('guest','read,write,execute,create,drop,alter','universe')
    box.schema.user.grant('guest', 'replication')
end)


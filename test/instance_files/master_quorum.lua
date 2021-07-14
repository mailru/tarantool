#!/usr/bin/env tarantool
local SOCKET_DIR = require('fio').cwd()
local TIMEOUT = tonumber(arg[1])

local function instance_uri(instance_id)
--     return 'localhost:'..(3314 + instance_id)
    return SOCKET_DIR..'/master_quorum'..(instance_id)..'.sock';
end

local workdir = os.getenv('TARANTOOL_WORKDIR')
box.cfg({
    work_dir = workdir,
    listen = os.getenv('TARANTOOL_LISTEN');
    replication = {
        instance_uri(1);
        instance_uri(2);
    };
    replication_connect_quorum = 0;
    replication_timeout = TIMEOUT;
})

box.once("bootstrap", function()
    box.schema.user.grant('guest','read,write,execute,create,drop,alter,replication','universe')
    box.schema.space.create('test', {engine = os.getenv('ENGINE')})
    box.space.test:create_index('primary')
end)

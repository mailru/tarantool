#!/usr/bin/env tarantool
local SOCKET_DIR = require('fio').cwd()

box.cfg({
    work_dir = os.getenv('TARANTOOL_WORKDIR'),
--     listen              = 'localhost:3314',
    listen              = SOCKET_DIR..'/replica_no_quorum.sock',
--     replication         = 'localhost:3310',
    replication = SOCKET_DIR..'/quorum_master.sock',
    memtx_memory        = 107374182,
    replication_connect_quorum = 0,
    replication_timeout = 0.1,
})

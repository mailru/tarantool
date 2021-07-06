#!/usr/bin/env tarantool

box.cfg({
    work_dir = os.getenv('TARANTOOL_WORKDIR'),
    listen              = 'localhost:3314',
    replication         = 'localhost:3310',
    memtx_memory        = 107374182,
    replication_connect_quorum = 0,
    replication_timeout = 0.1,
})


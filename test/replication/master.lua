#!/usr/bin/env tarantool
os = require('os')
box.cfg({
    listen              = os.getenv("LISTEN"),
    memtx_memory        = 107374182,
})

require('console').listen(os.getenv('ADMIN'))

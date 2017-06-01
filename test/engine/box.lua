#!/usr/bin/env tarantool
os = require('os')

local vinyl = {
    threads = 3,
    range_size=1024*64,
    page_size=1024,
}

box.cfg{
    listen              = os.getenv("LISTEN"),
    memtx_memory        = 107374182,
    pid_file            = "tarantool.pid",
    rows_per_wal        = 50,
    vinyl_threads       = 3,
    vinyl_range_size    = 64 * 1024,
    vinyl_page_size     = 1024,
}

require('console').listen(os.getenv('ADMIN'))

_to_exclude = {
    'pid_file', 'log', 'vinyl_dir',
    'memtx_dir', 'wal_dir',
    'memtx_min_tuple_size', 'memtx_max_tuple_size'
}

_exclude = {}
for _, f in pairs(_to_exclude) do
    _exclude[f] = 1
end

function cfg_filter(data)
    local result = {}
    for field, val in pairs(data) do
        if _exclude[field] == nil then
            result[field] = val
        end
    end
    return result
end

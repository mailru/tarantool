#!/usr/bin/env tarantool

require('suite')

os.execute("rm -rf vinyl_test")
os.execute("mkdir -p vinyl_test")

box.cfg {
    listen            = os.getenv("LISTEN"),
    memtx_memory      = 107374182,
    pid_file          = "tarantool.pid",
    rows_per_wal      = 500000,
    vinyl_dir         = "./vinyl_test",
    vinyl_memory      = 107374182,
    vinyl_threads     = 5,
    vinyl_range_size  = 1024 * 1024,
    vinyl_page_size   = 4 * 1024,
}

require('console').listen(os.getenv('ADMIN'))

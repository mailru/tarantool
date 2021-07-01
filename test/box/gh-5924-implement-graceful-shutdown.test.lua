env = require('test_run')
net_box = require('net.box')
fiber = require('fiber')
test_run = env.new()

test_run:cmd("create server test with script='box/gh-5924-implement-graceful-shutdown.lua'")


test_run:cmd("start server test with args='10'")
server_addr = test_run:cmd("eval test 'return box.cfg.listen'")[1]

-- Check difference between close and shutdown connection:
-- after closing connection we getting error, after shutdown
-- responses
test_run:cmd("switch test")
s = box.schema.space.create('test', { engine = 'memtx' })
_ = s:create_index('primary')
test_run:cmd('switch default')

conn = net_box.connect(server_addr)
space = conn.space.test
futures = {}
results = {}
replace_count = 1000

for i = 1, replace_count do futures[i] = space:replace({i}, {is_async = true}) end
-- Give time to send requests to the server
fiber.yield()
conn:close()

err = nil
test_run:cmd("setopt delimiter ';'")
for i, future in pairs(futures) do
    results[i], err = future:wait_result()
    if err then
        break
    end
end;
assert(err);
test_run:cmd("setopt delimiter ''");

test_run:cmd("switch test")
s:truncate()
test_run:cmd('switch default')

conn = net_box.connect(server_addr)
space = conn.space.test
futures = {}
results = {}
for i = 1, replace_count do futures[i] = space:replace({i}, {is_async = true}) end
-- Give time to send requests to the server
fiber.yield()
-- Shutdown socket for write, does not prevent
-- getting responses from the server
conn:shutdown()

err = nil
test_run:cmd("setopt delimiter ';'")
for i, future in pairs(futures) do
    results[i], err = future:wait_result()
    if err then
        break
    end
end;
assert(not err);
test_run:cmd("setopt delimiter ''");
-- example content of `results` table
-- [1]
results[1]
-- [2]
results[2]
-- [3]
results[3]

-- error: Peer closed
-- Server received 0 after shutdown and closed
-- connection after processing all requests
space:replace({replace_count + 1})

test_run:cmd("switch test")
s:drop()
test_run:cmd('switch default')

test_run:cmd("stop server test")
test_run:cmd("cleanup server test")
test_run:cmd("delete server test")

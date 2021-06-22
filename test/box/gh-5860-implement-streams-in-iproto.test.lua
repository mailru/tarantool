env = require('test_run')
net_box = require('net.box')
test_run = env.new()

test_run:cmd("create server test with script='box/gh-5860-implement-streams.lua'")

-- Some simple checks for new object - stream
test_run:cmd("start server test with args='1'")
server_addr = test_run:cmd("eval test 'return box.cfg.listen'")[1]
-- User can use automatically generated stream_id or sets it
-- manually, not mix this.
conn = net_box.connect(server_addr)
stream = conn:stream()
-- Error unable to mix user and automatically generated stream_id
-- for one connection.
_ = conn:stream(1)
conn:close()
conn = net_box.connect(server_addr)
stream = conn:stream(1)
-- Error unable to mix user and automatically generated stream_id
-- for one connection.
_ = conn:stream()
conn:close()
-- For different connections it's ok
conn_1 = net_box.connect(server_addr)
stream_1 = conn_1:stream(1)
conn_2 = net_box.connect(server_addr)
stream_2 = conn_2:stream()
-- Stream is a wrapper around connection, so if you close connection
-- you close stream, and vice versa.
conn_1:close()
assert(not stream_1:ping())
stream_2:close()
assert(not conn_2:ping())
-- Simple checks for transactions
conn_1 = net_box.connect(server_addr)
conn_2 = net_box.connect(server_addr)
stream_1_1 = conn_1:stream(1)
stream_1_2 = conn_1:stream(2)
-- It's ok to have streams with same id for different connections
stream_2 = conn_2:stream(1)
-- It's ok to commit or rollback without any active transaction
stream_1_1:commit()
stream_1_1:rollback()

stream_1_1:begin()
-- Error unable to start second transaction in one stream
stream_1_1:begin()
-- It's ok to start transaction in separate stream in one connection
stream_1_2:begin()
-- It's ok to start transaction in separate stream in other connection
stream_2:begin()
test_run:cmd("switch test")
-- It's ok to start local transaction separately with active stream
-- transactions
box.begin()
box.commit()
test_run:cmd("switch default")
stream_1_1:commit()
stream_1_2:commit()
stream_2:commit()

--Check that spaces in stream object updates, during reload_schema
conn = net_box.connect(server_addr)
stream = conn:stream()
test_run:cmd("switch test")
-- Create one space on server
s = box.schema.space.create('test', { engine = 'memtx' })
_ = s:create_index('primary')
test_run:cmd("switch default")
assert(not conn.space.test)
assert(not stream.space.test)
conn:reload_schema()
assert(conn.space.test ~= nil)
assert(stream.space.test ~= nil)
test_run:cmd("switch test")
s:drop()
test_run:cmd("switch default")
conn:reload_schema()
assert(not conn.space.test)
assert(not stream.space.test)

test_run:cmd("stop server test")

-- All test works with iproto_thread count = 10

-- Second argument (false is a value for memtx_use_mvcc_engine option)
-- Server start without active transaction manager, so all transaction
-- fails because of yeild!
test_run:cmd("start server test with args='10, false'")
server_addr = test_run:cmd("eval test 'return box.cfg.listen'")[1]

test_run:cmd("switch test")
s = box.schema.space.create('test', { engine = 'memtx' })
_ = s:create_index('primary')
test_run:cmd('switch default')

conn = net_box.connect(server_addr)
assert(conn:ping())
stream = conn:stream()
space = stream.space.test

-- Check syncronious stream txn requests for memtx
-- with memtx_use_mvcc_engine = false
stream:begin()
test_run:cmd('switch test')
errinj = box.error.injection
assert(errinj.get('ERRINJ_IPROTO_STREAMS_COUNT') == 1)
test_run:cmd('switch default')
space:replace({1})
-- Empty select, transaction was not commited and
-- is not visible from requests not belonging to the
-- transaction.
space:select{}
-- Select is empty, because memtx_use_mvcc_engine is false
space:select({})
test_run:cmd("switch test")
-- Select is empty, transaction was not commited
s:select()
test_run:cmd('switch default')
-- Commit fails, transaction yeild with memtx_use_mvcc_engine = false
stream:commit()
-- Select is empty, transaction was aborted
space:select{}
-- Check that after failed transaction commit we able to start next
-- transaction (it's strange check, but it's necessary because it was
-- bug with it)
stream:begin()
stream:ping()
stream:commit()
test_run:cmd('switch test')
s:drop()
-- Check that there are no streams and messages, which
-- was not deleted
errinj = box.error.injection
assert(errinj.get('ERRINJ_IPROTO_STREAMS_COUNT') == 0)
assert(errinj.get('ERRINJ_IPROTO_STREAMS_MSG_COUNT') == 0)
test_run:cmd('switch default')
test_run:cmd("stop server test")

-- Next we check transactions only for memtx with
-- memtx_use_mvcc_engine = true and for vinyl, because
-- if memtx_use_mvcc_engine = false all transactions fails,
-- as we can see before!

-- Second argument (true is a value for memtx_use_mvcc_engine option)
-- Same test case as previous but server start with active transaction
-- manager. Also check vinyl, because it's behaviour is same.
test_run:cmd("start server test with args='10, true'")
server_addr = test_run:cmd("eval test 'return box.cfg.listen'")[1]

test_run:cmd("switch test")
s1 = box.schema.space.create('test_1', { engine = 'memtx' })
s2 = box.schema.space.create('test_2', { engine = 'vinyl' })
_ = s1:create_index('primary')
_ = s2:create_index('primary')
test_run:cmd('switch default')

conn = net_box.connect(server_addr)
assert(conn:ping())
stream_1 = conn:stream()
stream_2 = conn:stream()
space_1 = stream_1.space.test_1
space_2 = stream_2.space.test_2
-- Spaces getting from connection, not from stream has no stream_id
-- and not belongs to stream
space_1_no_stream = conn.space.test_1
space_2_no_stream = conn.space.test_2
-- Check syncronious stream txn requests for memtx
-- with memtx_use_mvcc_engine = true and to vinyl:
-- behaviour is same!
stream_1:begin()
space_1:replace({1})
stream_2:begin()
space_2:replace({1})
test_run:cmd('switch test')
errinj = box.error.injection
assert(errinj.get('ERRINJ_IPROTO_STREAMS_COUNT') == 2)
test_run:cmd('switch default')
-- Empty select, transaction was not commited and
-- is not visible from requests not belonging to the
-- transaction.
space_1_no_stream:select{}
space_2_no_stream:select{}
-- Select return tuple, which was previously inserted,
-- because this select belongs to transaction.
space_1:select({})
space_2:select({})
test_run:cmd("switch test")
-- Select is empty, transaction was not commited
s1:select()
s2:select()
test_run:cmd('switch default')
-- Commit was successful, transaction can yeild with
-- memtx_use_mvcc_engine = true. Vinyl transactions
-- can yeild also.
stream_1:commit()
stream_2:commit()
test_run:cmd("switch test")
-- Check that there are no streams and messages, which
-- was not deleted after commit
errinj = box.error.injection
assert(errinj.get('ERRINJ_IPROTO_STREAMS_COUNT') == 0)
assert(errinj.get('ERRINJ_IPROTO_STREAMS_MSG_COUNT') == 0)
test_run:cmd("switch default")

-- Select return tuple, which was previously inserted,
-- because transaction was successful
space_1:select{}
space_2:select{}
test_run:cmd("switch test")
-- Select return tuple, which was previously inserted,
-- because transaction was successful
s1:select()
s2:select()
s1:drop()
s2:drop()
test_run:cmd('switch default')
test_run:cmd("stop server test")

-- Check conflict resolution in stream transactions,
test_run:cmd("start server test with args='10, true'")
server_addr = test_run:cmd("eval test 'return box.cfg.listen'")[1]

test_run:cmd("switch test")
s1 = box.schema.space.create('test_1', { engine = 'memtx' })
_ = s1:create_index('primary')
s2 = box.schema.space.create('test_2', { engine = 'vinyl' })
_ = s2:create_index('primary')
test_run:cmd('switch default')

conn = net_box.connect(server_addr)
stream_1 = conn:stream()
stream_2 = conn:stream()
space_1_1 = stream_1.space.test_1
space_1_2 = stream_2.space.test_1
space_2_1 = stream_1.space.test_2
space_2_2 = stream_2.space.test_2
stream_1:begin()
stream_2:begin()

-- Simple read/write conflict.
space_1_1:select({1})
space_1_2:select({1})
space_1_1:replace({1, 1})
space_1_2:replace({1, 2})
stream_1:commit()
-- This transaction fails, because of conflict
stream_2:commit()
test_run:cmd("switch test")
-- Check that there are no streams and messages, which
-- was not deleted after commit
errinj = box.error.injection
assert(errinj.get('ERRINJ_IPROTO_STREAMS_COUNT') == 0)
assert(errinj.get('ERRINJ_IPROTO_STREAMS_MSG_COUNT') == 0)
test_run:cmd("switch default")
-- Here we must accept [1, 1]
space_1_1:select({})
space_1_2:select({})

-- Same test for vinyl sapce
stream_1:begin()
stream_2:begin()
space_2_1:select({1})
space_2_2:select({1})
space_2_1:replace({1, 1})
space_2_2:replace({1, 2})
stream_1:commit()
-- This transaction fails, because of conflict
stream_2:commit()
test_run:cmd("switch test")
-- Check that there are no streams and messages, which
-- was not deleted after commit
errinj = box.error.injection
assert(errinj.get('ERRINJ_IPROTO_STREAMS_COUNT') == 0)
assert(errinj.get('ERRINJ_IPROTO_STREAMS_MSG_COUNT') == 0)
test_run:cmd("switch default")
-- Here we must accept [1, 1]
space_2_1:select({})
space_2_2:select({})

test_run:cmd('switch test')
-- Both select return tuple [1, 1], transaction commited
s1:select()
s2:select()
s1:drop()
s2:drop()
test_run:cmd('switch default')
test_run:cmd("stop server test")

-- Check rollback as a command for memtx and vinyl spaces
test_run:cmd("start server test with args='10, true'")
server_addr = test_run:cmd("eval test 'return box.cfg.listen'")[1]

test_run:cmd("switch test")
s1 = box.schema.space.create('test_1', { engine = 'memtx' })
_ = s1:create_index('primary')
s2 = box.schema.space.create('test_2', { engine = 'vinyl' })
_ = s2:create_index('primary')
test_run:cmd('switch default')

conn = net_box.connect(server_addr)
stream_1 = conn:stream()
stream_2 = conn:stream()
space_1 = stream_1.space.test_1
space_2 = stream_2.space.test_2
stream_1:begin()
stream_2:begin()

-- Test rollback for memtx space
space_1:replace({1})
-- Select return tuple, which was previously inserted,
-- because this select belongs to transaction.
space_1:select({})
stream_1:rollback()
-- Select is empty, transaction rollback
space_1:select({})

-- Test rollback for vinyl space
space_2:replace({1})
-- Select return tuple, which was previously inserted,
-- because this select belongs to transaction.
space_2:select({})
stream_2:rollback()
-- Select is empty, transaction rollback
space_2:select({})

test_run:cmd("switch test")
-- Check that there are no streams and messages, which
-- was not deleted after rollback
errinj = box.error.injection
assert(errinj.get('ERRINJ_IPROTO_STREAMS_COUNT') == 0)
assert(errinj.get('ERRINJ_IPROTO_STREAMS_MSG_COUNT') == 0)
test_run:cmd("switch default")

-- This is simple test is necessary because i have a bug
-- with halting stream after rollback
stream_1:begin()
stream_1:commit()
stream_2:begin()
stream_2:commit()
conn:close()

test_run:cmd('switch test')
-- Both select are empty, because transaction rollback
s1:select()
s2:select()
s1:drop()
s2:drop()
test_run:cmd('switch default')
test_run:cmd("stop server test")

-- Check rollback on disconnect
test_run:cmd("start server test with args='10, true'")
server_addr = test_run:cmd("eval test 'return box.cfg.listen'")[1]

test_run:cmd("switch test")
s1 = box.schema.space.create('test_1', { engine = 'memtx' })
_ = s1:create_index('primary')
s2 = box.schema.space.create('test_2', { engine = 'vinyl' })
_ = s2:create_index('primary')
test_run:cmd('switch default')

conn = net_box.connect(server_addr)
stream_1 = conn:stream(1)
stream_2 = conn:stream(2)
space_1 = stream_1.space.test_1
space_2 = stream_2.space.test_2
stream_1:begin()
stream_2:begin()

space_1:replace({1})
space_1:replace({2})
-- Select return two previously inserted tuples
space_1:select({})

space_2:replace({1})
space_2:replace({2})
-- Select return two previously inserted tuples
space_2:select({})
conn:close()

test_run:cmd("switch test")
-- Check that there are no streams and messages, which
-- was not deleted after connection close
errinj = box.error.injection
assert(errinj.get('ERRINJ_IPROTO_STREAMS_COUNT') == 0)
assert(errinj.get('ERRINJ_IPROTO_STREAMS_MSG_COUNT') == 0)
test_run:cmd("switch default")

-- Reconnect
conn = net_box.connect(server_addr)
stream_1 = conn:stream(1)
stream_2 = conn:stream(2)
space_1 = stream_1.space.test_1
space_2 = stream_2.space.test_2
-- We can begin new transactions with same stream_id, because
-- previous one was rollbacked and destroyed.
stream_1:begin()
stream_2:begin()
-- Two empty selects
space_1:select({})
space_2:select({})
stream_1:commit()
stream_2:commit()

test_run:cmd('switch test')
-- Both select are empty, because transaction rollback
s1:select()
s2:select()
s1:drop()
s2:drop()
test_run:cmd('switch default')
test_run:cmd("stop server test")

-- Check that all requests between `begin` and `commit`
-- have correct lsn and tsn values. During my work on the
-- patch, i see that all requests in stream comes with
-- header->is_commit == true, so if we are in transaction
-- in stream we should set this value to false, otherwise
-- during recovering `wal_stream_apply_dml_row` fails, because
-- of LSN/TSN mismatch. Here is a special test case for it.
test_run:cmd("start server test with args='10, true'")
server_addr = test_run:cmd("eval test 'return box.cfg.listen'")[1]

test_run:cmd("switch test")
s = box.schema.space.create('test', { engine = 'memtx' })
_ = s:create_index('primary')
test_run:cmd('switch default')

conn = net_box.connect(server_addr)
stream = conn:stream()
space = stream.space.test

stream:begin()
space:replace({1})
space:replace({2})
stream:commit()

test_run:cmd('switch test')
-- Here we get two tuples, commit was successful
s:select{}
s:drop()
test_run:cmd('switch default')
test_run:cmd("stop server test")

test_run:cmd("start server test with args='1, true'")
test_run:cmd("stop server test")

-- Same transactions checks for async mode
test_run:cmd("start server test with args='10, true'")
server_addr = test_run:cmd("eval test 'return box.cfg.listen'")[1]

test_run:cmd("switch test")
s1 = box.schema.space.create('test_1', { engine = 'memtx' })
_ = s1:create_index('primary')
s2 = box.schema.space.create('test_2', { engine = 'vinyl' })
_ = s2:create_index('primary')
test_run:cmd('switch default')

conn = net_box.connect(server_addr)
assert(conn:ping())
stream_1 = conn:stream()
space_1 = stream_1.space.test_1
stream_2 = conn:stream()
space_2 = stream_2.space.test_2

memtx_futures = {}
memtx_results = {}
memtx_futures["begin"] = stream_1:begin({is_async = true})
memtx_futures["replace"] = space_1:replace({1}, {is_async = true})
memtx_futures["insert"] = space_1:insert({2}, {is_async = true})
memtx_futures["select"] = space_1:select({}, {is_async = true})

vinyl_futures = {}
vinyl_results = {}
vinyl_futures["begin"] = stream_2:begin({is_async = true})
vinyl_futures["replace"] = space_2:replace({1}, {is_async = true})
vinyl_futures["insert"] = space_2:insert({2}, {is_async = true})
vinyl_futures["select"] = space_2:select({}, {is_async = true})

test_run:cmd("switch test")
-- Select is empty, transaction was not commited
s1:select()
s2:select()
test_run:cmd('switch default')
memtx_futures["commit"] = stream_1:commit({is_async = true})
vinyl_futures["commit"] = stream_2:commit({is_async = true})

test_run:cmd("setopt delimiter ';'")
for name, future in pairs(memtx_futures) do
    local err
    memtx_results[name], err = future:wait_result()
    assert(not err)
end;
for name, future in pairs(vinyl_futures) do
    local err
    vinyl_results[name], err = future:wait_result()
    assert(not err)
end;
test_run:cmd("setopt delimiter ''");
-- If begin was successful it return nil
assert(not memtx_results["begin"])
assert(not vinyl_results["begin"])
-- [1]
assert(memtx_results["replace"])
assert(vinyl_results["replace"])
-- [2]
assert(memtx_results["insert"])
assert(vinyl_results["insert"])
-- [1] [2]
assert(memtx_results["select"])
assert(vinyl_results["select"])
-- If commit was successful it return nil
assert(not memtx_results["commit"])
assert(not vinyl_results["commit"])

test_run:cmd("switch test")
-- Select return tuple, which was previously inserted,
-- because transaction was successful
s1:select()
s2:select()
s1:drop()
s2:drop()
errinj = box.error.injection
assert(errinj.get('ERRINJ_IPROTO_STREAMS_COUNT') == 0)
assert(errinj.get('ERRINJ_IPROTO_STREAMS_MSG_COUNT') == 0)
test_run:cmd('switch default')
test_run:cmd("stop server test")

-- Check conflict resolution in stream transactions,
test_run:cmd("start server test with args='10, true'")
server_addr = test_run:cmd("eval test 'return box.cfg.listen'")[1]

test_run:cmd("switch test")
s1 = box.schema.space.create('test_1', { engine = 'memtx' })
_ = s1:create_index('primary')
s2 = box.schema.space.create('test_2', { engine = 'vinyl' })
_ = s2:create_index('primary')
test_run:cmd('switch default')

conn = net_box.connect(server_addr)
stream_1 = conn:stream()
stream_2 = conn:stream()
space_1_1 = stream_1.space.test_1
space_1_2 = stream_2.space.test_1
space_2_1 = stream_1.space.test_2
space_2_2 = stream_2.space.test_2

futures_1 = {}
results_1 = {}
-- Simple read/write conflict.
futures_1["begin_1"] = stream_1:begin({is_async = true})
futures_1["begin_2"] = stream_2:begin({is_async = true})
futures_1["select_1_1"] = space_1_1:select({1}, {is_async = true})
futures_1["select_1_2"] = space_1_2:select({1}, {is_async = true})
futures_1["replace_1_1"] = space_1_1:replace({1, 1}, {is_async = true})
futures_1["replace_1_2"] = space_1_2:replace({1, 2}, {is_async = true})
futures_1["commit_1"] = stream_1:commit({is_async = true})
futures_1["commit_2"] = stream_2:commit({is_async = true})
futures_1["select_1_1_A"] = space_1_1:select({}, {is_async = true})
futures_1["select_1_2_A"] = space_1_2:select({}, {is_async = true})

test_run:cmd("setopt delimiter ';'")
for name, future in pairs(futures_1) do
    local err
    results_1[name], err = future:wait_result()
    if err then
    	results_1[name] = err
    end
end;
test_run:cmd("setopt delimiter ''");
-- Successful begin return nil
assert(not results_1["begin_1"])
assert(not results_1["begin_2"])
-- []
assert(not results_1["select_1_1"][1])
assert(not results_1["select_1_2"][1])
-- [1]
assert(results_1["replace_1_1"][1])
-- [1]
assert(results_1["replace_1_1"][2])
-- [1]
assert(results_1["replace_1_2"][1])
-- [2]
assert(results_1["replace_1_2"][2])
-- Successful commit return nil
assert(not results_1["commit_1"])
-- Error because of transaction conflict
assert(results_1["commit_2"])
-- [1, 1]
assert(results_1["select_1_1_A"][1])
-- commit_1 could have ended before commit_2, so
-- here we can get both empty select and [1, 1]
-- for results_1["select_1_2_A"][1]

futures_2 = {}
results_2 = {}
-- Simple read/write conflict.
futures_2["begin_1"] = stream_1:begin({is_async = true})
futures_2["begin_2"] = stream_2:begin({is_async = true})
futures_2["select_2_1"] = space_2_1:select({1}, {is_async = true})
futures_2["select_2_2"] = space_2_2:select({1}, {is_async = true})
futures_2["replace_2_1"] = space_2_1:replace({1, 1}, {is_async = true})
futures_2["replace_2_2"] = space_2_2:replace({1, 2}, {is_async = true})
futures_2["commit_1"] = stream_1:commit({is_async = true})
futures_2["commit_2"] = stream_2:commit({is_async = true})
futures_2["select_2_1_A"] = space_2_1:select({}, {is_async = true})
futures_2["select_2_2_A"] = space_2_2:select({}, {is_async = true})

test_run:cmd("setopt delimiter ';'")
for name, future in pairs(futures_2) do
    local err
    results_2[name], err = future:wait_result()
    if err then
    	results_2[name] = err
    end
end;
test_run:cmd("setopt delimiter ''");
-- Successful begin return nil
assert(not results_2["begin_1"])
assert(not results_2["begin_2"])
-- []
assert(not results_2["select_2_1"][1])
assert(not results_2["select_2_2"][1])
-- [1]
assert(results_2["replace_2_1"][1])
-- [1]
assert(results_2["replace_2_1"][2])
-- [1]
assert(results_2["replace_2_2"][1])
-- [2]
assert(results_2["replace_2_2"][2])
-- Successful commit return nil
assert(not results_2["commit_1"])
-- Error because of transaction conflict
assert(results_2["commit_2"])
-- [1, 1]
assert(results_2["select_2_1_A"][1])
-- commit_1 could have ended before commit_2, so
-- here we can get both empty select and [1, 1]
-- for results_1["select_2_2_A"][1]

test_run:cmd('switch test')
-- Both select return tuple [1, 1], transaction commited
s1:select()
s2:select()
s1:drop()
s2:drop()
errinj = box.error.injection
assert(errinj.get('ERRINJ_IPROTO_STREAMS_COUNT') == 0)
assert(errinj.get('ERRINJ_IPROTO_STREAMS_MSG_COUNT') == 0)
test_run:cmd('switch default')
test_run:cmd("stop server test")

-- Checks for iproto call/eval in stream
test_run:cmd("start server test with args='10, true'")
server_addr = test_run:cmd("eval test 'return box.cfg.listen'")[1]
test_run:cmd("switch test")
s = box.schema.space.create('test', { engine = 'memtx' })
_ = s:create_index('primary')
function ping() return "pong" end
test_run:cmd('switch default')

conn = net_box.connect(server_addr)
assert(conn:ping())
stream = conn:stream()
space = stream.space.test
space_no_stream = conn.space.test


-- error: Transaction is active at return from function
stream:call('box.begin')
stream:eval('box.begin()')

stream:begin()
stream:call('ping')
stream:eval('ping()')
-- error: Operation is not permitted when there is an active transaction
stream:call('box.begin')
stream:eval('box.begin()')
-- successful commit using call
stream:call('box.commit')

stream:begin()
space:replace({1})
-- Empty select, transaction was not commited and
-- is not visible from requests not belonging to the
-- transaction.
space_no_stream:select{}
-- Select return tuple, which was previously inserted,
-- because this select belongs to transaction.
space:select({})
test_run:cmd("switch test")
-- Select is empty, transaction was not commited
s:select()
test_run:cmd('switch default')
--Successful commit using stream:eval
stream:eval('box.commit()')
-- Select return tuple, which was previously inserted,
-- because transaction was successful
space_no_stream:select{}
test_run:cmd("switch test")
-- Select return tuple, because transaction was successful
s:select()
s:delete{1}
test_run:cmd('switch default')
-- Check rollback using stream:call
stream:begin()
space:replace({2})
-- Empty select, transaction was not commited and
-- is not visible from requests not belonging to the
-- transaction.
space_no_stream:select{}
-- Select return tuple, which was previously inserted,
-- because this select belongs to transaction.
space:select({})
test_run:cmd("switch test")
-- Select is empty, transaction was not commited
s:select()
test_run:cmd('switch default')
--Successful rollback using stream:call
stream:call('box.rollback')
-- Empty selects transaction rollbacked
space:select({})
space_no_stream:select{}
test_run:cmd("switch test")
-- Empty select transaction rollbacked
s:select()
s:drop()
errinj = box.error.injection
assert(errinj.get('ERRINJ_IPROTO_STREAMS_COUNT') == 0)
assert(errinj.get('ERRINJ_IPROTO_STREAMS_MSG_COUNT') == 0)
test_run:cmd('switch default')
test_run:cmd("stop server test")

-- Simple test which demostrates that stream immediately
-- destroyed, when no processing messages in stream and
-- no active transaction.

test_run:cmd("start server test with args='10, true'")
server_addr = test_run:cmd("eval test 'return box.cfg.listen'")[1]
test_run:cmd("switch test")
s = box.schema.space.create('test', { engine = 'memtx' })
_ = s:create_index('primary')
test_run:cmd('switch default')

conn = net_box.connect(server_addr)
assert(conn:ping())
stream = conn:stream()
space = stream.space.test
for i = 1, 10 do space:replace{i} end
test_run:cmd("switch test")
-- All messages was processed, so stream object was immediately
-- deleted, because no active transaction started.
errinj = box.error.injection
assert(errinj.get('ERRINJ_IPROTO_STREAMS_COUNT') == 0)
assert(errinj.get('ERRINJ_IPROTO_STREAMS_MSG_COUNT') == 0)
s:drop()
test_run:cmd('switch default')
test_run:cmd("stop server test")

test_run:cmd("cleanup server test")
test_run:cmd("delete server test")

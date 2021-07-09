env = require('test_run')
test_run = env.new()
test_run:cmd("create server test6040 with script='box/gh-6040-hash-not-tracked-by-mvcc.lua'")
test_run:cmd("start server test6040")
test_run:cmd("switch test6040")

txn_proxy = require('txn_proxy')

test_space = box.schema.space.create('test_hash')
test_idx = test_space:create_index('test', {type='hash'})

tx = txn_proxy.new()

tx:begin()
tx('test_space:select{}')
test_space:replace{1, 1}
tx('test_space:select{}')
tx:commit()

test_space:drop()

test_run:cmd("switch default")
test_run:cmd("stop server test6040")
test_run:cmd("cleanup server test6040")

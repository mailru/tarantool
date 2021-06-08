env = require('test_run')
test_run = env.new()

test_run:cmd("create server test with script='box/tx_man.lua'")
test_run:cmd("start server test")
test_run:cmd("switch test")

-- The main goal of the test is to verify that rollback triggers of _user
-- system space will work as desired in case of replace. The easiest way
-- to fire rollback triggers is to use mvcc feature.
-- 
txn_proxy = require('txn_proxy')

tx1 = txn_proxy.new()
tx2 = txn_proxy.new()

tx1:begin()
tx2:begin()

tx1("box.schema.user.create('internal1')")
tx2("box.schema.user.create('internal2')")

tx1:commit()
tx2:commit()

test_run:cmd("switch default")
test_run:cmd("stop server test")
test_run:cmd("cleanup server test")


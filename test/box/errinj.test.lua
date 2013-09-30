space = box.schema.create_space('tweedledum')
space:create_index('primary', 'hash', { parts = { 0, 'num' }})

box.errinj.info()
box.errinj.set("some-injection", true)
box.errinj.set("some-injection") -- check error
space:select(0,222444)
box.errinj.set("ERRINJ_TESTING", true)
space:select(0,222444)
box.errinj.set("ERRINJ_TESTING", false)

-- Check how well we handle a failed log write
box.errinj.set("ERRINJ_WAL_IO", true)
space:insert(1)
space:select(0,1)
box.errinj.set("ERRINJ_WAL_IO", false)
space:insert(1)
box.errinj.set("ERRINJ_WAL_IO", true)
space:update(1, '=p', 0, 2)
space:select(0,1)
space:select(0,2)
box.errinj.set("ERRINJ_WAL_IO", false)
space:truncate()

-- Check a failed log rotation
box.errinj.set("ERRINJ_WAL_ROTATE", true)
space:insert(1)
space:select(0,1)
box.errinj.set("ERRINJ_WAL_ROTATE", false)
space:insert(1)
box.errinj.set("ERRINJ_WAL_ROTATE", true)
space:update(1, '=p', 0, 2)
space:select(0,1)
space:select(0,2)
box.errinj.set("ERRINJ_WAL_ROTATE", false)
space:update(1, '=p', 0, 2)
space:select(0,1)
space:select(0,2)
box.errinj.set("ERRINJ_WAL_ROTATE", true)
space:truncate()
box.errinj.set("ERRINJ_WAL_ROTATE", false)
space:truncate()

space:drop()

-- Check how well we handle a failed log write in DDL
s_disabled = box.schema.create_space('disabled')
s_withindex = box.schema.create_space('withindex')
s_withindex:create_index('primary', 'hash')
s_withdata = box.schema.create_space('withdata')
s_withdata:create_index('primary', 'tree')
s_withdata:insert(1, 2, 3, 4, 5)
s_withdata:insert(4, 5, 6, 7, 8)
s_withdata:create_index('secondary', 'hash', {parts = {1, 'num', 2, 'num' }})
box.errinj.set("ERRINJ_WAL_IO", true)
test = box.schema.create_space('test')
s_disabled:create_index('primary', 'hash')
s_disabled.enabled
s_disabled:insert(0)
s_withindex:create_index('secondary', 'tree', { parts = { 1, 'num'} })
s_withindex.index.secondary
s_withdata.index.secondary:drop()
s_withdata.index.secondary.unique
s_withdata:drop()
box.space['withdata'].enabled
s_withdata:create_index('another', 'tree', {parts = { 4, 'num' }, unique = false})
s_withdata.index.another
box.errinj.set("ERRINJ_WAL_IO", false)
test = box.schema.create_space('test')
s_disabled:create_index('primary', 'hash')
s_disabled.enabled
s_disabled:insert(0)
s_withindex:create_index('secondary', 'tree', { parts = { 1, 'num'} })
s_withindex.index.secondary.unique
s_withdata.index.secondary:drop()
s_withdata.index.secondary
s_withdata:drop()
box.space['withdata']
s_withdata:create_index('another', 'tree', {parts = { 4, 'num' }, unique = false})
s_withdata.index.another
test:drop()
s_disabled:drop()
s_withindex:drop()

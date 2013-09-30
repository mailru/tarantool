-- clear statistics
--# stop server default
--# start server default

space = box.schema.create_space('tweedledum', { id = 0 })
space:create_index('primary', 'hash', { parts = { 0, 'num' }})


-- check stat_cleanup
-- add several tuples
for i=1,10 do box.insert(0, i, 'tuple'..tostring(i)) end;
box.stat()

--# stop server default
--# start server default

-- statistics must be zero
box.stat()

-- cleanup
box.space[0]:drop()

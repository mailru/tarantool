-- ----------------------------------------------------------------
-- LIMITS
-- ----------------------------------------------------------------
box.schema.SYSTEM_ID_MIN
box.schema.FIELD_MAX
box.schema.INDEX_FIELD_MAX
box.schema.NAME_MAX
box.schema.INDEX_ID
box.schema.SPACE_ID
box.schema.INDEX_MAX
box.schema.SPACE_MAX
box.schema.SYSTEM_ID_MAX
box.schema.SCHEMA_ID
box.schema.FORMAT_ID_MAX
-- ----------------------------------------------------------------
-- CREATE SPACE
-- ----------------------------------------------------------------

s = box.schema.create_space('tweedledum')
-- space already exists
box.schema.create_space('tweedledum')
-- create if not exists
s = box.schema.create_space('tweedledum', { if_not_exists = true })

s:drop()
-- no such space
s:drop()
-- explicit space id
s = box.schema.create_space('tweedledum', { id = 3000 })
s.n
-- duplicate id
box.schema.create_space('tweedledee', { id = 3000 })
-- stupid space id
box.schema.create_space('tweedledee', { id = 'tweedledee' })
s:drop()
-- too long space name
box.schema.create_space(string.rep('tweedledee', 100))
-- space name limit
box.schema.create_space(string.rep('t', box.schema.NAME_MAX)..'_')
s = box.schema.create_space(string.rep('t', box.schema.NAME_MAX - 1)..'_')
s.name
s:drop()
s = box.schema.create_space(string.rep('t', box.schema.NAME_MAX - 2)..'_')
s.name
s:drop()
-- space with no indexes - test update, delete, select, truncate
s = box.schema.create_space('tweedledum')
s:insert(0)
s:select(0)
s:select_range(0, 0, 0)
s:delete(0)
s:update(0, "=p", 0, 0)
s:replace(0)
s.index[0]
s:truncate()
s.enabled
-- enabled/disabled transition
s:create_index('primary', 'hash', { parts = { 0, 'num' } })
s.enabled
-- rename space - same name
s:rename('tweedledum')
s.name
-- rename space - different name
s:rename('tweedledee')
s.name
-- the reference from box.space[] to the space by old name should be gone
box.space['tweedledum']
-- rename space - bad name
s:rename(string.rep('t', box.schema.NAME_MAX * 2))
s.name
-- access to a renamed space
s:insert(0)
s:delete(0)
-- cleanup
s:drop()
-- create a space with reserved id (ok, but warns in the log)
s = box.schema.create_space('test', { id = 256 })
s.n
s:drop()
s = box.schema.create_space('test', { arity = 2 })
s.arity
s:create_index('primary', 'tree', { parts = { 0, 'num' } })
-- arity actually works
s:insert(1)
s:insert(1, 2)
s:insert(1, 2, 3)
s:select(0)
-- increase arity -- error
box.space['_space']:update(s.n, "=p", 1, 3)
s:select(0)
-- decrease arity - error
box.space['_space']:update(s.n, "=p", 1, 1)
-- remove arity - ok
box.space['_space']:update(s.n, "=p", 1, 0)
s:select(0)
-- increase arity - error
box.space['_space']:update(s.n, "=p", 1, 3)
s:truncate()
s:select(0)
-- set arity of an empty space
box.space['_space']:update(s.n, "=p", 1, 3)
s:select(0)
-- arity actually works
s:insert(3, 4)
s:insert(3, 4, 5)
s:insert(3, 4, 5, 6)
s:insert(7, 8, 9)
s:select(0)
-- check transition of space from enabled to disabled on
-- deletion of the primary key
s.enabled
s.index[0]:drop()
s.enabled
s.index[0]

-- "disabled" on
-- deletion of primary key
s:drop()
-- ----------------------------------------------------------------
-- CREATE INDEX
-- ----------------------------------------------------------------
--
s = box.schema.create_space('test')
--# setopt delimiter ';'
for k=0, box.schema.INDEX_MAX + 1, 1 do
    s:create_index('i'..k, 'hash', { parts = {0, 'num'} } )
end;
--# setopt delimiter ''
-- cleanup
for k, v in pairs (s.index) do if v.id ~= 0 then v:drop() end end
-- test limits enforced in key_def_check:
-- unknown index type
s:create_index('test', 'nosuchtype', { parts = {0, 'num'} })
-- hash index is not unique
s:create_index('test', 'hash', {parts = {0, 'num'}, unique = false })
-- bitset index is unique
s:create_index('test', 'bitset', {parts = {0, 'num'}, unique = true })
-- bitset index is multipart
s:create_index('test', 'bitset', {parts = {0, 'num', 1, 'num'}})
-- part count must be positive
s:create_index('test', 'hash', {parts = {}})
-- part count must be positive
s:create_index('test', 'hash', {parts = { 0 }})
-- unknown field type
s:create_index('test', 'hash', {parts = { 0, 'nosuchtype' }})
-- bad field no
s:create_index('test', 'hash', {parts = { 'qq', 'nosuchtype' }})
-- big field no
s:create_index('test', 'hash', {parts = { box.schema.FIELD_MAX, 'num' }})
s:create_index('test', 'hash', {parts = { box.schema.FIELD_MAX - 1, 'num' }})
s:create_index('test', 'hash', {parts = { box.schema.FIELD_MAX + 90, 'num' }})
s:create_index('test', 'hash', {parts = { box.schema.INDEX_FIELD_MAX + 1, 'num' }})
s:create_index('t1', 'hash', {parts = { box.schema.INDEX_FIELD_MAX, 'num' }})
s:create_index('t2', 'hash', {parts = { box.schema.INDEX_FIELD_MAX - 1, 'num' }})
-- cleanup
s:drop()
s = box.schema.create_space('test')
-- same part can't be indexed twice
s:create_index('t1', 'hash', {parts = { 0, 'num', 0, 'str' }})
-- a lot of key parts
parts = {}
--# setopt delimiter ';'
for k=0, box.schema.INDEX_PART_MAX, 1 do
    table.insert(parts, k)
    table.insert(parts, 'num')
end;
#parts;
s:create_index('t1', 'hash', {parts = parts});
parts = {};
for k=1, box.schema.INDEX_PART_MAX, 1 do
    table.insert(parts, k)
    table.insert(parts, 'num')
end;
#parts;
s:create_index('t1', 'hash', {parts = parts});
--# setopt delimiter ''
-- this is actually incorrect since key_field is a lua table
-- and length of a lua table which has index 0 set is not correct
#s.index[0].key_field
-- cleanup
s:drop()
-- check costraints in tuple_format_new()
s = box.schema.create_space('test')
s:create_index('t1', 'hash', { parts = { 0, 'num' }})
-- field type contradicts field type of another index
s:create_index('t2', 'hash', { parts = { 0, 'str' }})
-- ok
s:create_index('t2', 'hash', { parts = { 1, 'str' }})
-- don't allow drop of the primary key in presence of other keys
s.index[0]:drop()
-- cleanup
s:drop()
-- index name, name manipulation
s = box.schema.create_space('test')
s:create_index('primary', 'hash')
-- space cache is updated correctly
s.index[0].name
s.index[0].id
s.index[0].type
s.index['primary'].name
s.index['primary'].id
s.index['primary'].type
s.index.primary.name
s.index.primary.id
-- other properties are preserved
s.index.primary.type
s.index.primary.unique
s.index.primary:rename('new')
s.index[0].name
s.index.primary
s.index.new.name
-- too long name
s.index[0]:rename(string.rep('t', box.schema.NAME_MAX)..'_')
s.index[0].name
s.index[0]:rename(string.rep('t', box.schema.NAME_MAX - 1)..'_')
s.index[0].name
s.index[0]:rename(string.rep('t', box.schema.NAME_MAX - 2)..'_')
s.index[0].name
s.index[0]:rename('primary')
s.index.primary.name
-- cleanup
s:drop()
-- modify index
s = box.schema.create_space('test')
s:create_index('primary', 'hash')
s.index.primary:alter({unique=false})
-- unique -> non-unique, index type
s.index.primary:alter({type='tree', unique=false, name='pk'})
s.index.primary
s.index.pk.type
s.index.pk.unique
s.index.pk:rename('primary')
s:create_index('second', 'tree', { parts = {  1, 'str' } })
s.index.second.id
s:create_index('third', 'hash', { parts = {  2, 'num64' } })
s.index.third:rename('second')
s.index.third.id
s.index.second:drop()
s.index.third:alter({id = 1, name = 'second'})
s.index.third
s.index.second.name
s.index.second.id
s:drop()
-- ----------------------------------------------------------------
-- BUILD INDEX: changes of a non-empty index
-- ----------------------------------------------------------------
s = box.schema.create_space('full')
s:create_index('primary', 'tree', {parts =  { 0, 'str' }})
s:insert('No such movie', 999)
s:insert('Barbara', 2012)
s:insert('Cloud Atlas', 2012)
s:insert('Almanya - Willkommen in Deutschland', 2011)
s:insert('Halt auf freier Strecke', 2011)
s:insert('Homevideo', 2011)
s:insert('Die Fremde', 2010)
-- create index with data
s:create_index('year', 'tree', { unique=false, parts = { 1, 'num'} })
s.index.primary:select()
-- a duplicate in the created index
s:create_index('nodups', 'tree', { unique=true, parts = { 1, 'num'} })
-- change of non-unique index to unique: same effect
s.index.year:alter({unique=true})
-- num -> str -> num transition
box.space['_index']:update({s.n, s.index.year.id}, "=p", 7, 'str')
s.index.primary:select()
box.space['_index']:update({s.n, s.index.year.id}, "=p", 7, 'num')
-- ambiguous field type
s:create_index('str', 'tree', {unique =  false, parts = { 1, 'str'}})
-- create index on a non-existing field
s:create_index('nosuchfield', 'tree', {unique = true, parts = { 2, 'str'}})
s.index.year:drop()
s:insert('Der Baader Meinhof Komplex', '2009 ')
-- create an index on a field with a wrong type
s:create_index('year', 'tree', {unique = false, parts = { 1, 'num'}})
-- a field is missing
s:replace('Der Baader Meinhof Komplex')
s:create_index('year', 'tree', {unique = false, parts = { 1, 'num'}})
s:drop()
-- unique -> non-unique transition
s = box.schema.create_space('test')
-- primary key must be unique
s:create_index('primary', 'tree', { unique = false, parts = {0, 'num'}})
-- create primary key
s:create_index('primary', 'hash', { unique = true, parts = {0, 'num'}})
s:insert(1, 1)
s:create_index('secondary', 'tree', { unique = false, parts = {1, 'num'}})
s:insert(2, 1)
s.index.secondary:alter({ unique = true })
s:delete(2)
s.index.secondary:alter({ unique = true })
s:insert(2, 1)
s:insert(2, 2)
s.index.secondary:alter({ unique = false})
s:insert(3, 2)
s:drop()
-- ----------------------------------------------------------------
-- SPACE CACHE: what happens to a space cache when an object is gone
-- ----------------------------------------------------------------
s = box.schema.create_space('test')
s1 = s
s:create_index('primary', 'tree')
s1.index.primary.id
primary = s1.index.primary
s.index.primary:drop()
primary.id
primary:select()
s:drop()
-- @todo: add a test case for dangling iterator (currently no checks
-- for a dangling iterator in the code
-- ----------------------------------------------------------------
-- ----------------------------------------------------------------
-- RECOVERY: check that all indexes are correctly built
-- during recovery regardless of when they are created
-- ----------------------------------------------------------------
-- primary, secondary keys in a snapshot
s_empty = box.schema.create_space('s_empty')
s_empty:create_index('primary', 'tree', {unique = true, parts = {0, 'num'}})
s_empty:create_index('secondary', 'hash', {unique = true, parts = {1, 'num'}})

s_full = box.schema.create_space('s_full')
s_full:create_index('primary', 'tree', {unique = true, parts = {0, 'num'}})
s_full:create_index('secondary', 'hash', {unique = true, parts = {1, 'num'}})

s_full:insert(1, 1, 'a')
s_full:insert(2, 2, 'b')
s_full:insert(3, 3, 'c')
s_full:insert(4, 4, 'd')
s_full:insert(5, 5, 'e')

s_nil = box.schema.create_space('s_nil')

s_drop = box.schema.create_space('s_drop')

box.snapshot()

s_drop:drop()

s_nil:create_index('primary', 'hash', {unique=true, parts = {0, 'num'}})
s_nil:insert(1,2,3,4,5,6);
s_nil:insert(7, 8, 9, 10, 11,12)
s_nil:create_index('secondary', 'tree', {unique=false, parts = {1, 'num', 2, 'num', 3, 'num'}})
s_nil:insert(13, 14, 15, 16, 17)

r_empty = box.schema.create_space('r_empty')
r_empty:create_index('primary', 'tree', {unique = true, parts = {0, 'num'}})
r_empty:create_index('secondary', 'hash', {unique = true, parts = {1, 'num'}})

r_full = box.schema.create_space('r_full')
r_full:create_index('primary', 'tree', {unique = true, parts = {0, 'num'}})
r_full:create_index('secondary', 'hash', {unique = true, parts = {1, 'num'}})

r_full:insert(1, 1, 'a')
r_full:insert(2, 2, 'b')
r_full:insert(3, 3, 'c')
r_full:insert(4, 4, 'd')
r_full:insert(5, 5, 'e')

s_full:create_index('multikey', 'tree', {unique = true, parts = { 1, 'num', 2, 'str'}})
s_full:insert(6, 6, 'f')
s_full:insert(7, 7, 'g')
s_full:insert(8, 8, 'h')

r_disabled = box.schema.create_space('r_disabled')

--# stop server default
--# start server default

s_empty = box.space['s_empty']
s_full = box.space['s_full']
s_nil = box.space['s_nil']
s_drop = box.space['s_drop']
r_empty = box.space['r_empty']
r_full = box.space['r_full']
r_disabled = box.space['r_disabled']

s_drop

s_empty.index.primary.type
s_full.index.primary.type
r_empty.index.primary.type
r_full.index.primary.type
s_nil.index.primary.type

s_empty.index.primary.name
s_full.index.primary.name
r_empty.index.primary.name
r_full.index.primary.name
s_nil.index.primary.name

s_empty.enabled
s_full.enabled
r_empty.enabled
r_full.enabled
s_nil.enabled
r_disabled.enabled

s_empty.index.secondary.name
s_full.index.secondary.name
r_empty.index.secondary.name
r_full.index.secondary.name
s_nil.index.secondary.name

s_empty.index.primary:count(1)
s_full.index.primary:count(1)
r_empty.index.primary:count(1)
r_full.index.primary:count(1)
s_nil.index.primary:count(1)

s_empty.index.secondary:count(1)
s_full.index.secondary:count(1)
r_empty.index.secondary:count(1)
r_full.index.secondary:count(1)
s_nil.index.secondary:count(1)

-- cleanup
s_empty:drop()
s_full:drop()
r_empty:drop()
r_full:drop()
s_nil:drop()
r_disabled:drop()

--
-- @todo usability
-- ---------
-- - space name in all error messages!
--         error: Duplicate key exists in unique index 1 (ugly)
--
-- @todo features
--------
-- - ffi function to enable/disable space

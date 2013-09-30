--# create server replica with configuration='replication/cfg/replica.cfg'
--# start server replica
--# setopt delimiter ';'
--# set connection default
box.replace(box.schema.SPACE_ID, 0, 0, 'tweedledum');
box.replace(box.schema.INDEX_ID, 0, 0, 'primary', 'hash', 1, 1, 0, 'num');

--# set connection default, replica
function _insert(_begin, _end, msg) 
    a = {}
    for i = _begin, _end do
        table.insert(a, box.insert(0, i, msg..' - '..i))
    end
    return unpack(a)
end;

begin_lsn = box.info.lsn;

function _select(_begin, _end)
    a = {}
    while box.info.lsn < begin_lsn + _end do
        box.fiber.sleep(0.001)
    end
    for i = _begin, _end do
        table.insert(a, box.select(0, 0, i))
    end
    return unpack(a)
end;

--# setopt delimiter ''

--# set connection default
_insert(1, 10, 'master')
_select(1, 10)
--# set connection replica
_select(1, 10)

--# set connection default
-- Master LSN:
box.info.lsn
--# set connection replica 
-- Replica LSN:
box.info.lsn

-----------------------------
--  Master LSN > Replica LSN
-----------------------------
--------------------
-- Replica to Master
--------------------
--# reconfigure server replica with configuration 'replication/cfg/replica_to_master.cfg'
--# set connection default
_insert(11, 20, 'master')
_select(11, 20)
--# set connection replica
_insert (11, 15, 'replica')
_select (11, 15)

--# set connection default
-- Master LSN:
box.info.lsn
--# set connection replica 
-- Replica LSN:
box.info.lsn

-------------------
-- rollback Replica
-------------------
--# reconfigure server replica with configuration='replication/cfg/replica.cfg'
_select(11, 20)
--# set connection default
-- Master LSN:
box.info.lsn
--# set connection replica 
-- Replica LSN:
box.info.lsn

------------------------------
--  Master LSN == Replica LSN
------------------------------
--------------------
-- Replica to Master
--------------------
--# reconfigure server replica with configuration='replication/cfg/replica_to_master.cfg'
--# set connection default
_insert(21, 30, 'master')
_select(21, 30)
--# set connection replica
_insert(21, 30, 'replica')
_select(21, 30)

--# set connection default
-- Master LSN:
box.info.lsn
--# set connection replica 
-- Replica LSN:
box.info.lsn

-------------------
-- rollback Replica
-------------------
--# reconfigure server replica with configuration='replication/cfg/replica.cfg'
_select(21, 30)

--# set connection default
-- Master LSN:
box.info.lsn
--# set connection replica 
-- Replica LSN:
box.info.lsn

-----------------------------
--  Master LSN < Replica LSN
-----------------------------
--------------------
-- Replica to Master
--------------------
--# reconfigure server replica with configuration='replication/cfg/replica_to_master.cfg'
--# set connection default
_insert(31, 40, 'master')
_select(31, 40)
--# set connection replica
_insert(31, 50, 'replica')
_select(31, 50)

--# set connection default
-- Master LSN:
box.info.lsn
--# set connection replica 
-- Replica LSN:
box.info.lsn

-------------------
-- rollback Replica
-------------------
--# reconfigure server replica with configuration='replication/cfg/replica.cfg'
_select(31, 50)
--# set connection default
_insert(41, 60, 'master')
--# set connection replica
_select(41, 60)

--# set connection default
-- Master LSN:
box.info.lsn
--# set connection replica 
-- Replica LSN:
box.info.lsn

-- Test that a replica replies with master connection URL on update request
box.insert(0, 0, 'replica is RO')
--# stop server replica
--# cleanup server replica
--# set connection default
box.space[0]:drop();

local t = require('luatest')
local log = require('log')
local fio = require('fio')
local Process = t.Process
local root = fio.dirname(fio.dirname(fio.abspath(package.search('test.helper')))) -- luacheck: ignore
local datadir = fio.pathjoin(root, 'tmp', 'quorum_test')
local Cluster =  require('cluster')
local pgroup = require('pgroup')

local pgroup = pgroup.new('quorum', {
    engine = {'memtx', 'vinyl'},
--     engine = {'memtx'},
})

local master
local replica
local cluster

local workdir = fio.pathjoin(datadir, 'flomaster')

pgroup:set_before_each(function(g)
    local engine = g.params.engine
    fio.mktree(workdir)
    cluster = Cluster:new({})
    master = cluster:build_server({args = {},}, {alias = 'quorum_master', }, engine, 'base_instance.lua')
    replica = cluster:build_server({}, {alias = 'replica_no_quorum'}, engine, 'replica_no_quorum.lua')

    fio.mktree(workdir)
    pcall(log.cfg, {level = 6})

--     box.cfg({
--         work_dir = workdir,
-- --         listen = 'localhost:3310'
--         listen = SOCKET_DIR..'/quorum'..(0)..'.sock',
--     })
--     box.schema.user.grant('guest', 'read,write,execute', 'universe', nil, {if_not_exists = true})
    fio.mktree(fio.pathjoin(datadir, 'common'))

end)

pgroup:set_after_each(function()
    cluster.servers = nil
end)


pgroup:set_before_test('test_replication_no_quorum', function(g)
    cluster:join_server(master)
    cluster:join_server(replica)
    master:start()
    t.helpers.retrying({timeout = 20},
        function()
            t.assert(Process.is_pid_alive(master.process.pid),
                    master.alias .. ' failed on start')
            master:connect_net_box()
        end
    )
    master:eval("space = box.schema.space.create('test', {engine = " .. g.params.engine .."})")
    master:eval("index = space:create_index('primary')")
--     space = box.schema.space.create('test', {engine = g.params.engine})
--     index = space:create_index('primary') -- luacheck: ignore
end)

pgroup:set_after_test('test_replication_no_quorum', function()
--     space:drop()
    cluster:stop()
    fio.rmtree(datadir)
end)

pgroup:add('test_replication_no_quorum', function()
     -- gh-3278: test different replication and replication_connect_quorum configs.
    -- Insert something just to check that replica with quorum = 0 works as expected.

    t.assert_equals(master:eval("return space:insert{1}"), {1})
    replica:start()
    t.helpers.retrying({timeout = 20},
        function()
            t.assert(Process.is_pid_alive(replica.process.pid),
                    replica.alias .. ' failed on start')
            replica:connect_net_box()
            t.assert_str_matches(
                replica:eval('return box.info.status'), 'running')
        end
    )
    t.assert_equals(
        replica:eval('return box.space.test:select()'), {{1}})
    replica:stop()

--     local listen = box.cfg.listen
    master:eval("local listen = box.cfg.listen")
    master:eval("return box.cfg{listen = ''}")

    replica:start()
    t.helpers.retrying({timeout = 10},
        function()
            t.assert(Process.is_pid_alive(replica.process.pid),
                    replica.alias .. ' failed on start')
            replica:connect_net_box()
            t.assert_str_matches(
                replica:eval('return box.info.status'), 'running')
        end
    )

    -- Check that replica is able to reconnect, case was broken with earlier quorum "fix".
    master:eval("return box.cfg{listen = listen}")
    t.assert_equals(master:eval("return space:insert{2}"), {2})
--  TODO: fix vclock
    local fiber = require('fiber')
--     fiber.sleep(2)
    local vclock = master:eval("return box.info.vclock")
    fiber.sleep(vclock[1])
--     local vclock = box.info.vclock
--     vclock[0] = nil
    t.assert_str_matches(
        replica:eval('return box.info.status'), 'running')
    t.assert_equals(master:eval("return space:select()"), {{1}, {2}})
--     t.assert_equals(
--         replica:eval('return box.space.test:select()'), {{1}, {2}})

end)

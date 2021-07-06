local t = require('luatest')
local log = require('log')
local fio = require('fio')
local g = t.group()
local Process = t.Process
local Server = t.Server
local fiber = require('fiber')
local root = fio.dirname(fio.dirname(fio.abspath(package.search('test.helper')))) -- luacheck: ignore
local datadir = fio.pathjoin(root, 'tmp', 'quorum_test')
local test_run = require('test_run').new()
local Cluster =  require('cluster')

local COUNT = 100

cluster = Cluster:new({})

g.before_all = function()

    quorum1 = cluster:build_server({args = {'0.1'},}, {alias = 'quorum1', })
    quorum2 = cluster:build_server({args = {'0.1'},}, {alias = 'quorum2', })
    quorum3 = cluster:build_server({args = {'0.1'},}, {alias = 'quorum3', })
    replica = cluster:build_server({}, {alias = 'replica_no_quorum'})
    master_quorum1 = cluster:build_server({args = {'0.1'},}, {alias = 'master_quorum1', })
    master_quorum2 = cluster:build_server({args = {'0.1'},}, {alias = 'master_quorum2', })
    replica_quorum = cluster:build_server({args = {'1', '0.05', '10'}}, {alias = 'replica_quorum'})

    local workdir = fio.pathjoin(datadir, 'master')
    fio.mktree(workdir)
    pcall(log.cfg, {level = 6})

    box.cfg({
        work_dir = workdir,
        listen = 'localhost:3310'
    })
    box.schema.user.grant('guest', 'read,write,execute', 'universe')
    fio.mktree(fio.pathjoin(datadir, 'common'))

end

g.after_all = function()
    cluster:stop()
    fio.rmtree(datadir)
end

g.test_replica_is_orphan_after_restart = function()
    log.info("start test_replica_is_orphan_after_restart")
    -- Stop one replica and try to restart another one.
    -- It should successfully restart, but stay in the
    -- 'orphan' mode, which disables write accesses.
    -- There are three ways for the replica to leave the
    -- 'orphan' mode:
    -- * reconfigure replication
    -- * reset box.cfg.replication_connect_quorum
    -- * wait until a quorum is formed asynchronously
    cluster:join_server(quorum1)
    cluster:join_server(quorum2)
    cluster:join_server(quorum3)
    cluster:start()


    quorum1:stop()
    quorum2:restart({'0.1', '10'})
    t.helpers.retrying({timeout = 15}, function()
        t.assert(Process.is_pid_alive(quorum2.process.pid))
        quorum2:connect_net_box()
    end)
    t.assert_equals(quorum2.net_box.state, 'active')
    t.assert_str_matches(
        quorum2:eval('return box.info.status'), 'orphan')
    t.assert_error_msg_content_equals('timed out', function()
            quorum2:eval('return box.ctl.wait_rw(0.001)')
    end)
    t.assert(quorum2:eval('return box.info.ro'))
    t.helpers.retrying({timeout = 20}, function()
        t.assert(quorum2:eval('return box.space.test ~= nil'))
    end)
    t.assert_error_msg_content_equals(
        "Can't modify data because this instance is in read-only mode.",
        function()
            quorum2:eval('return box.space.test:replace{100}')
        end
    )
    quorum2:eval('box.cfg{replication={}}')
    t.assert_str_matches(
        quorum2:eval('return box.info.status'), 'running')
    quorum2:restart({'0.1', '10'})
    t.helpers.retrying({timeout = 15}, function()
        t.assert(Process.is_pid_alive(quorum2.process.pid))
        quorum2:connect_net_box()
    end)
    t.assert_equals(quorum2.net_box.state, 'active')
    t.assert_str_matches(
        quorum2:eval('return box.info.status'), 'orphan')
    t.assert_error_msg_content_equals('timed out', function()
            quorum2:eval('return box.ctl.wait_rw(0.001)')
    end)
    t.assert(quorum2:eval('return box.info.ro'))
    t.helpers.retrying({timeout = 20}, function()
        t.assert(quorum2:eval('return box.space.test ~= nil'))
    end)
    t.assert_error_msg_content_equals(
        "Can't modify data because this instance is in read-only mode.",
        function()
            quorum2:eval('return box.space.test:replace{100}')
        end
    )
    quorum2:eval('box.cfg{replication_connect_quorum = 2}')
    quorum2:eval('return box.ctl.wait_rw()')
    t.assert_not(quorum2:eval('return box.info.ro'))
    t.assert_str_matches(
        quorum2:eval('return box.info.status'), 'running')
    quorum2:restart({'0.1', '10'})
    t.helpers.retrying({timeout = 15}, function()
        t.assert(Process.is_pid_alive(quorum2.process.pid))
        quorum2:connect_net_box()
    end)
    t.assert_equals(quorum2.net_box.state, 'active')
    t.assert_str_matches(
        quorum2:eval('return box.info.status'), 'orphan')
    t.assert_error_msg_content_equals('timed out', function()
            quorum2:eval('return box.ctl.wait_rw(0.001)')
    end)
    t.assert(quorum2:eval('return box.info.ro'))
    t.helpers.retrying({timeout = 20}, function()
        t.assert(quorum2:eval('return box.space.test ~= nil'))
    end)
    t.assert_error_msg_content_equals(
        "Can't modify data because this instance is in read-only mode.",
        function()
            quorum2:eval('return box.space.test:replace{100}')
        end
    )
    quorum1.args = {'0.1'}
    quorum1:start()
    t.helpers.retrying({timeout = 20},
        function()
            t.assert(Process.is_pid_alive(quorum1.process.pid),
                    quorum1.alias .. ' failed on start')
                quorum1:connect_net_box()
        end
    )
    t.assert_equals(quorum1.net_box.state, 'active',
        'wrong state for server="%s"', quorum1.alias)
    quorum1:eval('return box.ctl.wait_rw()')
    t.assert_not(quorum1:eval('return box.info.ro'))
    t.assert_str_matches(quorum1:eval('return box.info.status'), 'running')
end

g.test_replica_follows_all_masters = function()
    -- Check that the replica follows all masters.
--     log.info("start test")
--     cluster:join_server(quorum1)
--     cluster:join_server(quorum2)
--     cluster:join_server(quorum3)
--     cluster:start({quorum1, quorum2, quorum3})
    local servers = {quorum1, quorum2, quorum3}
    for i = 1, #servers do
        if servers[i]:eval('return box.info.id') ~= i then
            t.helpers.retrying({timeout = 20}, function()
               t.assert_equals(servers[i]:eval(
                   'return box.info.replication[' .. i .. '].upstream.status'),
                   'follow',
                   servers[i].alias .. ': this server does not follow others.')
            end)
        end
    end
end

g.test_box_cfg_doesnt_return_before_all_replicas_are_not_configured = function()
    -- Check that box.cfg() doesn't return until the instance
    -- catches up with all configured replicas.
    t.assert_equals(
        quorum3:eval(
            'return box.error.injection.set("ERRINJ_RELAY_TIMEOUT", 0.001)'),
        'ok')
    t.assert_equals(
        quorum2:eval(
            'return box.error.injection.set("ERRINJ_RELAY_TIMEOUT", 0.001)'),
        'ok')
    quorum1:stop()
    t.helpers.retrying({timeout = 20}, function()
        t.assert_not_equals(
            quorum2:eval('return box.space.test.index.primary'), nil)
    end)
    quorum2:eval(
        'for i = 1, ' .. COUNT .. ' do box.space.test:insert{i} end')
    quorum2:eval("fiber = require('fiber')")
    quorum2:eval('fiber.sleep(0.1)')
    quorum1.args = {'0.1'}
    quorum1:start()
    t.helpers.retrying({timeout = 20},
        function()
            t.assert(Process.is_pid_alive(quorum1.process.pid),
                    quorum1.alias .. ' failed on start')
            quorum1:connect_net_box()
        end
    )
    t.assert_equals(quorum1.net_box.state, 'active',
        'wrong state for server="%s"', quorum1.alias)
    t.helpers.retrying({timeout = 20}, function()
        t.assert_equals(
            quorum1:eval('return box.space.test:count()'), COUNT)
    end)
    -- Rebootstrap one node of the cluster and check that others follow.
    -- Note, due to ERRINJ_RELAY_TIMEOUT there is a substantial delay
    -- between the moment the node starts listening and the moment it
    -- completes bootstrap and subscribes. Other nodes will try and
    -- fail to subscribe to the restarted node during this period.
    -- This is OK - they have to retry until the bootstrap is complete.
    local servers = {quorum1, quorum2, quorum3}
    for _, server in ipairs(servers) do
        t.assert_equals(server:eval('return box.snapshot()'), 'ok')
    end
end

g.test_id_for_rebootstrapped_replica_with_removed_xlog = function()
    quorum1:stop()
    cluster:cleanup(quorum1.workdir)
    fio.rmtree(quorum1.workdir)
    fio.mktree(quorum1.workdir)
    -- The rebootstrapped replica will be assigned id = 4,
    -- because ids 1..3 are busy.
    quorum1.args = {'0.1'}
    quorum1:start()
    t.helpers.retrying({timeout = 20},
        function()
            t.assert(Process.is_pid_alive(quorum1.process.pid),
                    quorum1.alias .. ' failed on start')
            quorum1:connect_net_box()
        end
    )
    t.assert_equals(quorum1.net_box.state, 'active',
        'wrong state for server="%s"', quorum1.alias)
    t.helpers.retrying({timeout = 20}, function()
        t.assert_equals(
            quorum1:eval('return box.space.test:count()'), COUNT)
        t.assert_equals(
            quorum2:eval(
                'return box.info.replication[4].upstream.status'), 'follow')
        t.assert(quorum3:eval('return box.info.replication ~= nil'))
        t.assert_equals(
            quorum3:eval(
                'return box.info.replication[4].upstream.status'), 'follow')
    end)

    t.assert_equals(
        quorum2:eval('return box.info.replication[4].upstream.status'),
        'follow')
    t.assert_equals(
        quorum3:eval('return box.info.replication[4].upstream.status'),
        'follow')
    cluster:drop_cluster({quorum1, quorum2, quorum3})
end

g.test_replication_no_quorum = function()
     -- gh-3278: test different replication and replication_connect_quorum configs.
--      TODO: remove test_run by providing parameterized test
    test_run = require('test_run').new()
    local space = box.schema.space.create('test', {engine = test_run:get_cfg('engine')})
    local index = box.space.test:create_index('primary') -- luacheck: ignore
    -- Insert something just to check that replica with quorum = 0 works as expected.
    t.assert_equals(space:insert{1}, {1})
    replica:start()
    t.helpers.retrying({timeout = 20},
        function()
            t.assert(Process.is_pid_alive(replica.process.pid),
                    replica.alias .. ' failed on start')
            replica:connect_net_box()
        end
    )
    t.assert_str_matches(
        replica:eval('return box.info.status'), 'running')
    t.assert_equals(
        replica:eval('return box.space.test:select()'), {{1}})
    replica:stop()
    local listen = box.cfg.listen
    box.cfg{listen = ''}
    replica:start()
    t.helpers.retrying({timeout = 20},
        function()
            t.assert(Process.is_pid_alive(replica.process.pid),
                    replica.alias .. ' failed on start')
            replica:connect_net_box()
        end
    )
    t.assert_str_matches(
        replica:eval('return box.info.status'), 'running')

    -- Check that replica is able to reconnect, case was broken with earlier quorum "fix".
    box.cfg{listen = listen}
    t.assert_equals(space:insert{2}, {2})
--  TODO: fix vclock
    local fiber = require('fiber')
    fiber.sleep(2)
    local vclock = box.info.vclock
    vclock[0] = nil
    t.assert_str_matches(
        replica:eval('return box.info.status'), 'running')
    t.assert_equals(box.space.test:select(), {{1}, {2}})
    t.assert_equals(
        replica:eval('return box.space.test:select()'), {{1}, {2}})
    space:drop()
    cluster:drop_cluster({replica})
end

g.test_master_master_works = function()
    master_quorum1:start()
    master_quorum2:start()
    t.helpers.retrying({timeout = 20},
        function()
            t.assert(Process.is_pid_alive(master_quorum1.process.pid),
                    master_quorum1.alias .. ' failed on start')
            master_quorum1:connect_net_box()
            t.assert(Process.is_pid_alive(master_quorum2.process.pid),
                    master_quorum2.alias .. ' failed on start')
            master_quorum2:connect_net_box()
        end
    )
    master_quorum1:eval('repl = box.cfg.replication')
    master_quorum1:eval('box.cfg{replication = ""}')
    t.assert_equals(
        master_quorum1:eval('return box.space.test:insert{1}'), {1})
    master_quorum1:eval('box.cfg{replication = repl}')
    local vclock = master_quorum1:eval('return box.info.vclock')
    vclock[0] = nil

--     TODO: fix vclock
    fiber.sleep(2)
    t.assert_equals(
        master_quorum2:eval('return box.space.test:select()'), {{1}})

    cluster:drop_cluster({master_quorum1, master_quorum2})
end

g.test_quorum_during_reconfiguration = function()
    -- Test that quorum is not ignored neither during bootstrap, nor
    -- during reconfiguration.

    fiber.sleep(2)
    replica_quorum:start()
    t.helpers.retrying({timeout = 20},
        function()
            t.assert(Process.is_pid_alive(replica_quorum.process.pid),
                    replica_quorum.alias .. ' failed on start')
            replica_quorum:connect_net_box()
        end
    )
    -- If replication_connect_quorum was ignored here, the instance
    -- would exit with an error.
    t.assert_equals(
        replica_quorum:eval(
            'return box.cfg{replication={INSTANCE_URI, nonexistent_uri(1)}}'),
        nil)
    t.assert_equals(replica_quorum:eval('return box.info.id'), 1)
    cluster:drop_cluster({replica_quorum})
end

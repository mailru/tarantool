local log = require('log')
local t = require('luatest')
local fio = require('fio')
local Process = t.Process
local Server = t.Server

local root = fio.dirname(fio.dirname(fio.abspath(package.search('test.helper')))) -- luacheck: ignore
local datadir = fio.pathjoin(root, 'tmp', 'quorum_test')

local DEFAULT_CHECKPOINT_PATTERNS = {"*.snap", "*.xlog", "*.vylog",
                                     "*.inprogress", "[0-9]*/"}

local Cluster = {
    CONNECTION_TIMEOUT = 5,
    CONNECTION_RETRY_DELAY = 0.1,

    base_http_port = 3310,
}

function Cluster:new(object)
    self:inherit(object)
    object:initialize()
    self.servers = object.servers
    self.built_servers = object.built_servers
    return object
end

function Cluster:inherit(object)
    object = object or {}
    setmetatable(object, self)
    self.__index = self
    self.servers = {}
    self.built_servers = {}
    fio.rmtree(datadir)
    self.server_command = fio.pathjoin(root, '../test/replication-luatest', 'quorum.lua')
    return object
end

function Cluster:initialize()
    self.servers = {}
    self.server_command = fio.pathjoin(root, '../test/replication-luatest', 'quorum1.lua')
end

function Cluster:cleanup(path)
    for _, pattern in ipairs(DEFAULT_CHECKPOINT_PATTERNS) do
        fio.rmtree(fio.pathjoin(path, pattern))
    end
end

function Cluster:server(alias)
    for _, server in ipairs(self.servers) do
        if server.alias == alias then
            return server
        end
    end
    return nil
end

function Cluster:drop_cluster(servers)
    for _, server in ipairs(servers) do
        if server ~= nil then
            log.info('try to stop server: %s', server.alias)
            server:stop()
            self:cleanup(server.workdir)
            fio.rmtree(server.workdir)
        end
    end
end

function Cluster:get_index(server)
    local index = nil
    for i, v in ipairs(self.servers) do
        if (v.id == server) then
          index = i
        end
    end
    return index
end

function Cluster:delete_server(server)
    local idx = get_index(server)
    if idx == nil then
        print("Key does not exist")
    else
        table.remove(self.servers, idx)
    end
end

function Cluster:stop()
    for _, server in ipairs(self.built_servers) do
        log.info('try to stop server: %s', server.alias)
        server:stop()
    end
end

function Cluster:start()
    for _, server in ipairs(self.servers) do
        log.info("cluster start server: " .. server.alias)
        server:start()
    end
    t.helpers.retrying({timeout = 20},
        function()
            for _, server in ipairs(self.servers) do
                t.assert(Process.is_pid_alive(server.process.pid),
                    server.alias .. ' failed on start')
                server:connect_net_box()
            end
        end
    )
    for _, server in ipairs(self.servers) do
        log.info(server)
        t.assert_equals(server.net_box.state, 'active',
            'wrong state for server="%s"', server.alias)
    end
end

function Cluster:build_server(config, replicaset_config)
    replicaset_config = replicaset_config or {}
    local server_id = #self.built_servers + 1

    local server_config = {
        alias = replicaset_config.alias,
        command = fio.pathjoin(root, '../test/replication-luatest', replicaset_config.alias .. '.lua'),
        workdir = nil,
        net_box_port = self.base_http_port and (self.base_http_port + server_id),
    }
    for key, value in pairs(config) do
        server_config[key] = value
    end
    assert(server_config.alias, 'Either replicaset.alias or server.alias must be given')
    if server_config.workdir == nil then

        workdir = fio.pathjoin(datadir, server_config.alias)
        fio.mktree(workdir)
        server_config.workdir = workdir
    end
    log.info(server_config)
    server = Server:new(server_config)
    table.insert(self.built_servers, server)
    return server
end

function Cluster:join_server(server)
    log.info("join server: " .. server.alias)
    if self:server(server.alias) ~= nil then
        log.info("server already was joint: " .. server.alias)
        return
    end
    table.insert(self.servers, server)
end

function Cluster:build_and_join_server(config, replicaset_config)
    local server = self:build_server(config, replicaset_config)
    self:join_server(server)
    return server
end

return Cluster

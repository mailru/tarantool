#!/usr/bin/env tarantool

require('console').listen(os.getenv('ADMIN'))

local function prepare_table_with_success_listen_uri(idx, default_server_addr)
    assert(idx)
    local table_uries = {
        default_server_addr,
        { string.format("%s", default_server_addr) },
        { string.format("%sA", default_server_addr),
          string.format("%sB", default_server_addr) },
        { uri = string.format("%s", default_server_addr) },
        { uri = string.format("%s", default_server_addr), transport = "plain" },
        {
          string.format("%sA", default_server_addr),
          { uri = string.format("%s", default_server_addr), transport = "plain" }
        },
        {
          { uri = string.format("%sA", default_server_addr), transport = "plain" },
          { uri= string.format("%sB", default_server_addr), transport = "plain" }
        },
        { { uri = string.format("%s", default_server_addr), transport = {'plain', 'plain'} } },
        { { uri = string.format("%s", default_server_addr), transport = 'plain, plain' } },
        { { uri = string.format("%s", default_server_addr), transport = 'plain,,, plain' } },
        default_server_addr .. "A, " .. default_server_addr .. "B",
        default_server_addr .. "A?transport=plain, " .. default_server_addr .. "B?transport=plain",
        default_server_addr .. "?transport=plain&transport=plain",
        default_server_addr .. "A,,,,,, " .. default_server_addr .. "B", -- skip extra ','
        -- skip extra '?', '&', '=' and ';'
        default_server_addr .. "??&&transport==plain;;;plain&&transport==plain;;;plain",
        { transport = {'plain', 'plain'}, uri = string.format("%s", default_server_addr) },
        { { uri = string.format("%s", default_server_addr), transport = 'plain; plain' } },
        { { uri = string.format("%s", default_server_addr), transport = 'plain;;; plain' } },
    }
    return table_uries[idx]
end

local iproto_threads = 1
if arg[1] then
    iproto_threads = tonumber(arg[1])
end
local listen = os.getenv('LISTEN')
if arg[2] then
    listen = prepare_table_with_success_listen_uri(tonumber(arg[2]), listen)
end

box.cfg({
    listen = listen,
    iproto_threads = iproto_threads,
})

box.schema.user.grant("guest", "read,write,execute,create,drop", "universe", nil, {if_not_exists = true})

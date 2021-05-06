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
        default_server_addr .. "A, " .. default_server_addr .. "B",
        default_server_addr .. "A?transport=plain, " .. default_server_addr .. "B?transport=plain",
        default_server_addr .. "?transport=plain&transport=plain",
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

function prepare_table_with_fail_listen_uri(idx)
    assert(idx)
    local default_server_addr = box.cfg.listen
    local table_uries = {
        { "" },
        { "  " },
        { { uri = string.format("%s", default_server_addr) }, { uri = "  " } },
        { { uri = string.format("%s", default_server_addr) }, { uri = "?" } },
        { uri = string.format("%s", default_server_addr), transport = "unexpected_value" },
        { default_server_addr, uri = string.format("%s", default_server_addr), transport = "plain" },
        default_server_addr .. "?transport=",
        default_server_addr .. "?transport=plain&plain",
        default_server_addr .. "?unexpercted_option=unexpected_value",
        default_server_addr .. "?transport=plain,plain",
        "?/transport=plain",
        default_server_addr .. "?=transport=plain",
        { transport="plain" },
        { }
    }
    box.cfg ({ listen = table_uries[idx] })
end

function get_corresponding_error(idx)
    assert(idx)
    local table_uries_corresponding_errors = {
        "Incorrect value for option 'listen': uri can be empty, only if you pass it as one empty string",
        "Incorrect value for option 'listen': uri can be empty, only if you pass it as one empty string",
        "Incorrect value for option 'listen': uri can be empty, only if you pass it as one empty string",
        "Incorrect value for option 'listen': uri can be empty, only if you pass it as one empty string",
        "Incorrect value for option 'transport': expected plain value for uri transport option",
        "Incorrect value for option 'listen': invalid input format",
        "Incorrect value for option 'listen': expected uri?uri_option=uri_option_values",
        "Incorrect value for option 'listen': expected uri?uri_option=uri_option_values",
        "Incorrect value for option 'unexpercted_option': unexpected option",
        "Incorrect value for option 'listen': expected host:service or /unix.socket",
        "Incorrect value for option 'listen': uri can be empty, only if you pass it as one empty string",
        "Incorrect value for option 'listen': expected uri?uri_option=uri_option_values",
        "Incorrect value for option 'listen': uri can be empty, only if you pass it as one empty string",
        "Incorrect value for option 'listen': invalid input format"
    }
    return table_uries_corresponding_errors[idx]
end
local iproto_thread = require('iproto_thread')

this_module = {}

setmetatable(this_module, {
    __index = function(self, key)
         local idx = tonumber(key)
         if idx ~= nil then
             iproto_thread.check_idx(idx)
             return {
                 listen = function(uri) return iproto_thread.listen(idx, uri) end
             }
         end
         return nil
    end
})

package.loaded['iproto.thread'] = this_module
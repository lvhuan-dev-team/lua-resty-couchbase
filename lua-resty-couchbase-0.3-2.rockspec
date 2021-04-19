rockspec_format = "3.0"
package = "lua-resty-couchbase"
version = "0.3-2"
source = {
   url = "git+https://github.com/lvhuan-dev-team/lua-resty-couchbase.git"
}
description = {
   detailed = "lua-resty-couchbase - Lua couchbase client driver for the ngx_lua based on the cosocket API.",
   homepage = "https://github.com/lvhuan-dev-team/lua-resty-couchbase",
   license = "BSD License 2.0",
   labels = { "CouchBase", "OpenResty", "Cosocket", "Nginx" }
}
build = {
   type = "builtin",
   modules = {
      ["resty.couchbase"] = "lib/resty/couchbase.lua"
   }
}

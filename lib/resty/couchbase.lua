--
-- Lua couchbase client driver for the ngx_lua based on the cosocket API.
--
-- Copyright (C) 2020 iQIYI (www.iqiyi.com).
-- All Rights Reserved.
--

local bit = require "bit"
local cjson = require 'cjson'
local unpack = unpack
local http = require("resty.http")

local bor   = bit.bor
local bxor  = bit.bxor
local band  = bit.band
local tohex = bit.tohex

local lshift = bit.lshift
local rshift = bit.rshift

local min    = math.min
local random = math.random

local strbyte = string.byte
local strchar = string.char
local strfind = string.find
local strfmt  = string.format
local strlen  = string.len
local strsub  = string.sub
local strgsub = string.gsub
local strgmatch = string.gmatch

local tbl_concat = table.concat
local tbl_insert = table.insert
local tbl_sort   = table.sort

local ngx_gsub = ngx.re.gsub

local ngx_crc32 = ngx.crc32_short
local ngx_hmac_sha1 = ngx.hmac_sha1
--local ngx_md5      = ngx.md5
local ngx_md5_bin  = ngx.md5_bin
local ngx_sha1_bin = ngx.sha1_bin

local ngx_encode_args   = ngx.encode_args
local ngx_encode_base64 = ngx.encode_base64
local ngx_decode_base64 = ngx.decode_base64

local ngx_now = ngx.now
local ngx_log = ngx.log
local ngx_ctx = ngx.ctx

local ngx_sleep = ngx.sleep
local ngx_header = ngx.header
--local ngx_is_subrequest = ngx.is_subrequest

local ngx_INFO = ngx.INFO
local ngx_ERR  = ngx.ERR
local ngx_DEBUG = ngx.DEBUG

local ngx_socket_tcp = ngx.socket.tcp
local ngx_shared_ldict = ngx.shared.ldict


local _M = { _VERSION = '0.3-2' }
local mt = { __index = _M }

local _USER_AGENT = "lua-couchbase-client " .. _M._VERSION

local vbuckets = {}

local max_tries = 3
local default_timeout = 5000
local pool_max_idle_timeout = 10000
local pool_size = 100


local function log_info(...)
    ngx_log(ngx_INFO, ...)
end


local function log_error(...)
    ngx_log(ngx_ERR, ...)
end

local function log_debug(...)
    ngx_log(ngx_DEBUG, ...)
end


local function host2server(host_ports, need_random)

    local servers = {}
    for _, host_port in ipairs(host_ports) do
        local host = ngx_gsub(host_port, ':[0-9]+', '')
        local port = ngx_gsub(host_port, '[^:]+:', '')
        tbl_insert(servers, { host = host, port = tonumber(port), t = random(1, 100), name = host_port })
    end

    if need_random then
        tbl_sort(servers, function(a, b)
            return a.t > b.t
        end)
    end

    return servers
end


local function http_post(host, port, url, data, token)

    local httpc = http.new()
    local body_data = ngx_encode_args(data)

    local request = {
        method  = "POST",
        path    = url,
        body    = body_data,
        headers = {
            ["Content-Type"]    = "application/x-www-form-urlencoded",
            ["Content-Length"]  = #body_data,
            ["User-Agent"]      = _USER_AGENT,
            ["Authorization"]   = 'Basic ' .. token,
            ["Host"]            = host .. ":" .. port,
            ["Accept"]          = "*/*"
        }
    }

    local resp, err = httpc:request_uri("http://".. host .. ":" .. port, request)
    if not resp or err then
        log_error("请求失败！")
        return nil,err
    end

    return resp.body
end


local function http_request(host, port, url, token)

    local sock, err = ngx_socket_tcp()

    if not sock then
        return nil, err
    end

    sock:settimeout(default_timeout)
    local ok, connect_err = sock:connect(host, port)

    if not ok then
        return nil, connect_err
    end

    -- Only simple http 1.0 request. Not support the gzip and chunked.
    local request = {}
    request[#request + 1] = 'GET ' .. url .. ' HTTP/1.0\r\n'
    request[#request + 1] = 'User-Agent: '.. _USER_AGENT ..'\r\n'
    request[#request + 1] = 'Authorization: Basic ' .. token .. '\r\n'
    request[#request + 1] = 'Accept: */*\r\n'
    request[#request + 1] = '\r\n'

    local bytes, send_err = sock:send(tbl_concat(request))
    if not bytes then
        return nil, send_err
    end

    local length = 0
    while true do

        local header, header_err = sock:receive('*l')

        if not header then
            return nil, header_err
        end

        if strfind(header, 'Content%-Length:') then
            length = strgsub(header, 'Content%-Length:', '')
        end

        if not header or header == '' then
            break
        end
    end

    local body, body_err
    if tonumber(length) == 0 then
        body, body_err = sock:receive('*a')
    else
        body, body_err = sock:receive(tonumber(length))
    end

    if not body then
        return nil, body_err
    end

    return body
end


local function fetch_configs(servers, bucket_name, username, password)

    local configs = {}
    local token

    if password == nil then
        password = ''
    end

    token = ngx_encode_base64(username .. ':' .. password)

    local tries = min(max_tries, #servers)
    for try = 1, tries, 1 do
        local server = servers[try]

        log_info('try to fetch config ,from host=', server.host, ',port=', server.port, "token=", token)

        local body, err = http_request(server.host, server.port, '/pools/default/buckets/' .. bucket_name, token)
        if body then
            -- bug fixed with body is 'Requested resource not found.'.
            if strfind(body, '^{') then
                local config = cjson.decode(body)
                log_debug("fetch config" .. tostring(#configs + 1) .. ": ", body)
                configs[#configs + 1] = config
                break
            else
                log_debug(strfmt(
                    'fetch config is error,from host=%s, port=%s, username=%s, token=%s, server response body=%s',
                        server.host, server.port, username, token, body))
            end
        else
            log_debug(strfmt('fetch config is error,from host=%s, port=%s, username=%s, token=%s, err=%s',
                    server.host, server.port, username, token, err))
        end
    end

    log_debug("configs: ",cjson.encode(configs))
    return configs
end


local function create_vbucket(host_ports, bucket_name, username, password)

    local servers = host2server(host_ports, true)
    local vbucket = {
        host_ports  = host_ports,
        servers     = servers,
        name        = bucket_name,
        username    = username,
        password    = password,
        type    = 'membase',
        hash    = 'CRC',
        mast    = -1,
        nodes   = {},
        vmap    = {},
    }

    log_debug("vbucket: ", cjson.encode(vbucket))

    local configs = fetch_configs(servers, bucket_name, username, password)
    if #configs == 0 then
        return nil, 'fail to fetch configs.'
    end

    for _, config in ipairs(configs) do
        if config.name == bucket_name then
            if config['bucketType'] == 'membase' then
                local bucket = config['vBucketServerMap']
                if bucket then

                    vbucket.hash = bucket['hashAlgorithm']
                    vbucket.nodes = host2server(bucket['serverList'])

                    local bucket_map = bucket['vBucketMap']
                    vbucket.mast = #bucket_map - 1

                    local vmap  = vbucket.vmap
                    local nodes = vbucket.nodes

                    for _, map in ipairs(bucket_map) do
                        local master  = map[1]
                        local replica = map[2]
                        tbl_insert(vmap, { nodes[master + 1], nodes[replica + 1] })
                    end
                end
            elseif config['bucketType'] == 'memcached' then
                local node_servers = {}
                for node in ipairs(config['nodes']) do
                    local node_server = strgsub(node['hostname'], ':[0-9]+', node['ports'].direct)
                    node_servers[#node_servers + 1] = node_server
                end

                -- Tt's can be ngx_memcached_module.
                return nil, 'Not support the bucketType of memcached!'
            end
        end
    end

    log_debug("vbucket: ", cjson.encode(vbucket))
    return vbucket
end


local last_reload = 0

local function reload_vbucket(old_vbucket)
    -- reload time 15 seconds.
    if ngx_now() - last_reload > 15 then
        last_reload = ngx_now()
        log_debug('try to refresh couchbase conifg.')
        local new_vbucket = create_vbucket(old_vbucket.host_ports, old_vbucket.name,
                                           old_vbucket.username, old_vbucket.password)

        if new_vbucket then
            old_vbucket.mast  = new_vbucket.mast
            old_vbucket.nodes = new_vbucket.nodes
            old_vbucket.vmap  = new_vbucket.vmap
            old_vbucket.sock  = new_vbucket.sock
        end
    end
end


local function location_server(vbucket, packet)

    local vbucket_mast = vbucket.mast
    if vbucket_mast == -1 then
        return nil
    end

    local hash = ngx_crc32(packet.key)
    local node_index = band(band(rshift(hash, 16), 0x7fff), vbucket_mast)
    packet.vbucket_id = node_index

    return packet.is_replica and vbucket.vmap[node_index + 1][2] or vbucket.vmap[node_index + 1][1]
end


-- Not used this method.
local function ketama_hash(key)
    local bytes = ngx_md5_bin(key)
    return band(bor(lshift(bytes[4], 24), lshift(bytes[3], 16), lshift(bytes[2], 8), bytes[1]), 0xFFFFFFFF)
end


_M._unused_f1 = ketama_hash


local function byte2str(byte)
    return strchar(unpack(byte))
end


local function hmac(k, c)
    local k_opad = {}
    local k_ipad = {}

    if k then
        if strlen(k) > 64 then
            k = ngx_md5_bin(k)
        end
        for i = 1, strlen(k), 1 do
            k_opad[i] = strbyte(k, i)
            k_ipad[i] = strbyte(k, i)
        end
    end

    for i = 1, 64, 1 do
        k_opad[i] = bxor(k_opad[i] or 0x0, 0x5c)
        k_ipad[i] = bxor(k_ipad[i] or 0x0, 0x36)
    end
    k_opad = byte2str(k_opad)
    k_ipad = byte2str(k_ipad)

    -- hash(k_opad || hash(k_ipad,c))
    return ngx_md5(k_opad .. ngx_md5_bin(k_ipad .. c))
end


_M._unused_f5 = hmac


local function get_byte2(data, i)
    local a, b = strbyte(data, i, i + 1)
    return bor(lshift(a, 8), b), i + 2
end


local function get_byte4(data, i)
    local a, b, c, d = strbyte(data, i, i + 3)
    return bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d), i + 4
end


local function get_byte8(data, i)

    local a, b, c, d, e, f, g, h = strbyte(data, i, i + 7)
    local hi = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    local lo = bor(lshift(e, 24), lshift(f, 16), lshift(g, 8), h)

    return hi * 4294967296 + lo, i + 8
end


local function pad_zores(bytes, n)
    for _ = 1, n, 1 do
        bytes[#bytes + 1] = 0x00
    end
end


local function set_byte(bytes, n)
    bytes[#bytes + 1] = band(n, 0xff)
end


local function set_byte2(bytes, n)

    if n == 0x00 then
        pad_zores(bytes, n)
    end

    bytes[#bytes + 1] = band(rshift(n, 8), 0xff)
    bytes[#bytes + 1] = band(n, 0xff)
end


local function set_byte4(bytes, n)

    if n == 0x00 then
        pad_zores(bytes, n)
    end

    bytes[#bytes + 1] = band(rshift(n, 24), 0xff)
    bytes[#bytes + 1] = band(rshift(n, 16), 0xff)
    bytes[#bytes + 1] = band(rshift(n, 8), 0xff)
    bytes[#bytes + 1] = band(n, 0xff)
end


local function set_byte8(bytes, n)

    if n == 0x00 then
        pad_zores(bytes, n)
    end

    bytes[#bytes + 1] = band(rshift(n, 56), 0xff)
    bytes[#bytes + 1] = band(rshift(n, 48), 0xff)
    bytes[#bytes + 1] = band(rshift(n, 40), 0xff)
    bytes[#bytes + 1] = band(rshift(n, 32), 0xff)
    bytes[#bytes + 1] = band(rshift(n, 24), 0xff)
    bytes[#bytes + 1] = band(rshift(n, 16), 0xff)
    bytes[#bytes + 1] = band(rshift(n, 8), 0xff)
    bytes[#bytes + 1] = band(n, 0xff)
end


local function val_len(val)
    return val and strlen(val) or 0x00
end


local function extra_data(flags, expir)

    local bytes = {}
    set_byte4(bytes, flags)
    set_byte4(bytes, expir)

    return strchar(bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8])
end


local packet_meta = {}
local packet_mt = { __index = packet_meta }


function packet_meta:create_request(...)
    local req = {
        magic       = 0x80,
        opcode      = 0x00,
        key_len     = 0x00,
        extra_len   = 0x00,
        data_type   = 0x00,
        vbucket_id  = 0x00,
        total_len   = 0x00,
        opaque      = 0x00,
        cas         = 0x00,
        extra       = nil,
        key         = nil,
        value       = nil,
    }

    for k, v in pairs(...) do
        req[k] = v
    end

    setmetatable(req, packet_mt)
    return req
end


function packet_meta:create_response(...)
    local resp = {
        magic       = 0x81,
        opcode      = 0x00,
        key_len     = 0x00,
        extra_len   = 0x00,
        data_type   = 0x00,
        status      = 0x00,
        total_len   = 0x00,
        opaque      = 0x00,
        cas         = 0x00,
        extra       = nil,
        key         = nil,
        value       = nil,
    }

    for k, v in pairs(...) do
        resp[k] = v
    end

    setmetatable(resp, packet_mt)
    return resp
end


local function str_to_hex(data)

    local hex_str = ""
    for i=1, #data, 1 do
        hex_str = hex_str .. " " .. strfmt("%02X", data:byte(i))
    end

    return hex_str
end


_M._unused_f4 = str_to_hex


function packet_meta:send_packet(sock)

    local packet = self
    packet.key_len   = val_len(packet.key)
    packet.extra_len = val_len(packet.extra)
    packet.total_len = packet.key_len + packet.extra_len + val_len(packet.value)

    local header = {}
    set_byte(header, packet.magic)
    set_byte(header, packet.opcode)
    set_byte2(header, packet.key_len)

    set_byte(header, packet.extra_len)
    set_byte(header, packet.data_type)
    set_byte2(header, packet.vbucket_id)

--    if  packet.key == "PLAIN" and packet.value  then
--         packet.total_len = packet.total_len + 1
--     end

    set_byte4(header, packet.total_len)
    set_byte4(header, packet.opaque)
    set_byte8(header, packet.cas)

    local bytes = {}
    bytes[#bytes + 1] = byte2str(header)
    bytes[#bytes + 1] = packet.extra
    bytes[#bytes + 1] = packet.key

    -- if packet.key == "PLAIN" and packet.value then
    --     bytes[#bytes + 1] = strchar(0)
    -- end

    bytes[#bytes + 1] = packet.value
    return sock:send(tbl_concat(bytes))
end


local values = { 'extra', 'key', 'value' }


function packet_meta:read_packet(sock)

    local data, err = sock:receive(24)
    if not data then
        return nil, "failed to receive packet header: " .. err
    end

    local packet = self
    packet.magic     = strbyte(data, 1)
    packet.opcode    = strbyte(data, 2)
    packet.key_len   = get_byte2(data, 3)

    packet.extra_len = strbyte(data, 5)
    packet.data_type = strbyte(data, 6)
    packet.status    = get_byte2(data, 7)

    packet.total_len = get_byte4(data, 9)
    packet.opaque    = get_byte4(data, 13)
    packet.cas       = get_byte8(data, 17)

    local value_len = packet.total_len - packet.extra_len - packet.key_len
    local val_config = { extra = packet.extra_len, key = packet.key_len, value = value_len }
    for _, name in ipairs(values) do
        local len = val_config[name]
        if len > 0 then
            local val_data, val_err = sock:receive(len)
            if not val_data then
                return nil, "failed to receive packet: " .. val_err
            end
            packet[name] = val_data
        end
    end

    if packet.extra then
        -- We just same to ngx_http_memcached_module.
        local flag = get_byte4(packet.extra, 1)
        if band(flag, 0x0002) ~= 0 then
            ngx_header['Content-Encoding'] = 'gzip'
            -- sub_request does not get the Content-Encoding value.
            if ngx.is_subrequest then
                ngx_header['Sub-Req-Content-Encoding'] = 'gzip'
            end
        end

        -- Only support bool int long specil_data byte
        if flag == 0x100 then
            packet.value = strbyte(packet.value) == 0x31
        elseif flag > 0x100 and flag < 0x600 then
            local raw_value, num = packet.value, 0
            if value_len > 3 then
                -- BitOp is Only support the 32 bit. we just workround it.
                -- http://bitop.luajit.org/semantics.html
                local hex_num = { '0x' }
                for i = 1, value_len, 1 do
                    hex_num[#hex_num + 1] = tohex(strbyte(raw_value, i), 2)
                end
                num = tonumber(tbl_concat(hex_num, ''), 16)
            else
                for i = 1, value_len, 1 do
                    num = bor(lshift(num, 8), strbyte(raw_value, i))
                end
            end
            packet.value = num
        end
    end
    return packet
end


local function prcess_sock_packet(sock, packet)
    local bytes, err = packet:send_packet(sock)

    if not bytes then
        return nil, "failed to send packet: " .. err
    end

    return packet:read_packet(sock)
end


local magic_bytes = {
    req_c2s = 0x80,	-- Request packet from client to server
    res_s2c = 0x81,	-- Response packet from server to client
    res_felx= 0x18,	-- Response packet containing flex extras
    req_s2c = 0x82,	-- Request packet from server to client
    res_c2s = 0x83	-- Response packet from client to server
}


_M._unused_f0 = magic_bytes


local opcodes = {
    Hello = 0x1f,
    -- base opcode
    Get         = 0x00,
    Set         = 0x01,
    Add         = 0x02,
    Replace     = 0x03,
    Delete      = 0x04,
    Increment   = 0x05,
    Decrement   = 0x06,
    Quit        = 0x07,
    Flush       = 0x08,
    -- adv opcode
    GetQ        = 0x09,
    ['No-op']   = 0x0a,
    Version     = 0x0b,
    GetK        = 0x0c,
    GetKQ       = 0x0d,
    Append      = 0x0e,
    Prepend     = 0x0f,
    Stat        = 0x10,
    SetQ        = 0x11,
    AddQ        = 0x12,
    ReplaceQ    = 0x13,
    DeleteQ     = 0x14,
    IncrementQ  = 0x15,
    DecrementQ  = 0x16,
    QuitQ       = 0x17,
    FlushQ      = 0x18,
    AppendQ     = 0x19,
    PrependQ    = 0x1A,
    Verbosity   = 0x1b,
    Touch       = 0x1c,
    GAT         = 0x1d,
    GATQ        = 0x1e,
    HELO        = 0x1f,

    -- SASL opcode
    SASLList    = 0x20,
    SASLAuth    = 0x21,
    SASLStep    = 0x22,

    -- Ioctl
    IoctlGet    = 0x23,
    IoctlSet    = 0x24,

    -- Config
    ConfigValidate      = 0x25,
    ConfigReload        = 0x26,

    -- Audit
    AuditPut            = 0x27,
    AuditConfigReload   = 0x28,

    Shutdown            = 0x29,

    --not supported 0x30 ~ 0x3c
    RGet        = 0x30,
    RSet        = 0x31,
    RSetQ       = 0x32,
    RAppend     = 0x33,
    RAppendQ    = 0x34,
    RPrepend    = 0x35,
    RPrependQ   = 0x36,
    RDelete     = 0x37,
    RDeleteQ    = 0x38,
    RIncr       = 0x39,
    RIncrQ      = 0x3a,
    RDecr       = 0x3b,
    RDecrQ      = 0x3c,

    --VBucket
    SetVBucket  = 0x3d,
    GetVBucket  = 0x3e,
    DelVBucket  = 0x3f,

    -- TAP removed in 5.0 0x40 ~ 0x47
    TAPConnect  = 0x40,
    TAPMutation = 0x41,
    TAPDelete   = 0x42,
    TAPFlush    = 0x43,
    TAPOpaque   = 0x44,
    TAPVBucketSet       = 0x45,
    TAPCheckoutStart    = 0x46,
    TAPCheckpointEnd    = 0x47,

    GetAllVbSeqnos      = 0x48,

    --Dcp
    DcpOpen             = 0x50,
    DcpAddStream        = 0x51,
    DcpSloseStream      = 0x52,
    DcpStreamReq        = 0x53,
    DcpGetFailoverLog   = 0x54,
    DcpStreamEnd        = 0x55,
    DcpSnapshotMarker   = 0x56,
    DcpMutation         = 0x57,
    DcpDeletion         = 0x58,
    DcpExpiration       = 0x59,
    -- (obsolete)
    DcpFlush            = 0x5a,
    DcpSetVbucketState  = 0x5b,
    DcpNoop             = 0x5c,
    DcpBufferAcknowledgement = 0x5d,
    DcpControl          = 0x5e,
    DcpSystemEvent      = 0x5f,
    DcpPrepare          = 0x60,
    DcpSeqnoAcknowledged = 0x61,
    DcpCommit           = 0x62,
    DcpAbort            = 0x63,
    DcpSeqnoAdvanced    = 0x64,
    DcpOutOfSequenceOrderSnapshot = 0x65,

    --Persistence
    StopPersistence     = 0x80,
    StartPersistence    = 0x81,
    SetParam            = 0x82,
    GetReplica          = 0x83,
    --Bucket
    CreateBucket        = 0x85,
    DeleteBucket        = 0x86,
    ListBuckets         = 0x87,
    SelectBucket        = 0x89,

    ObserveSeqno        = 0x91,
    Observe             = 0x92,
    EvictKey            = 0x93,
    GetLocked           = 0x94,
    UnlockKey           = 0x95,
    GetFailoverLog      = 0x96,
    LastClosedCheckpoint = 0x97,
    --TAP removed in 5.0
    DeregisterTapClient = 0x9e,
    --(obsolete)
    ResetReplicationChain   = 0x9f,

    -- Meta
    GetMeta             = 0xa0,
    GetqMeta            = 0xa1,
    SetWithMeta         = 0xa2,
    SetqWithMeta        = 0xa3,
    AddWithMeta         = 0xa4,
    AddqWithMeta        = 0xa5,
    --(obsolete)
    SnapshotVbStates    = 0xa6,
    VbucketBatchCount   = 0xa7,
    DelWithMeta         = 0xa8,
    DelqWithMeta        = 0xa9,

    CreateCheckpoint    = 0xaa,
    --(obsolete)
    NotifyVbucketUpdate = 0xac,
    EnableTraffic       = 0xad,
    DisableTraffic      = 0xae,
    -- (obsolete)
    ChangeVbFilter      = 0xb0,
    CheckpointPersistence = 0xb1,
    ReturnMeta          = 0xb2,
    CompactDb           = 0xb3,

    -- cluster
    SetClusterConfig    = 0xb4,
    GetClusterConfig    = 0xb5,
    GetRandomKey        = 0xb6,
    SeqnoPersistence    = 0xb7,
    GetKeys             = 0xb8,

    -- Collections
    CollectionsSetManifest = 0xb9,
    CollectionsGetManifest = 0xba,
    CollectionsGetCollectionId  = 0xbb,
    CollectionsGetScopeId       = 0xbc,
    --(obsolete)
    SetDriftCounterState= 0xc1,
    GetAdjustedTime     = 0xc2,

    --Subdoc
    SubdocGet           = 0xc5,
    SubdocExists        = 0xc6,
    SubdocDictAdd       = 0xc7,
    SubdocDictUpsert    = 0xc8,
    SubdocDelete        = 0xc9,
    SubdocReplace       = 0xca,
    SubdocArrayPushLast = 0xcb,
    SubdocArrayPushFirst= 0xcc,
    SubdocArrayInsert   = 0xcd,
    SubdocArrayAddUnique= 0xce,
    SubdocCounter       = 0xcf,
    SubdocMultiLookup   = 0xd0,
    SubdocMultiMutation = 0xd1,
    SubdocGetCount      = 0xd2,
    -- (see https://docs.google.com/document/d/1vaQJxIA5nhWJqji7X2R1xQDZadb5PabfKAid1kVe65o )
    SubdocReplaceBodyWithXattr = 0xd3,

    Scrub               = 0xf0,
    IsaslRefresh        = 0xf1,
    SslCertsRefresh     = 0xf2,
    GetCmdTimer         = 0xf3,
    SetCtrlToken        = 0xf4,
    GetCtrlToken        = 0xf5,
    UpdateExternalUserPermissions = 0xf6,
    RBACRefresh         = 0xf7,
    AUTHProvider        = 0xf8,
    -- (for testing)
    DropPrivilege       = 0xfb,
    AdjustTimeOfDay     = 0xfc,
    EwouldblockCtl      = 0xfd,
    GetErrorPap         = 0xfe,
}

local opcode_quiet = {
    [opcodes.Get]       = opcodes.GetQ,
    [opcodes.Set]       = opcodes.SetQ,
    [opcodes.Add]       = opcodes.AddQ,
    [opcodes.Replace]   = opcodes.ReplaceQ,
    [opcodes.Delete]    = opcodes.DeleteQ,
    [opcodes.Increment] = opcodes.IncrementQ,
    [opcodes.Decrement] = opcodes.DecrementQ,
    [opcodes.Quit]      = opcodes.QuitQ,
    [opcodes.Flush]     = opcodes.FlushQ,
    [opcodes.GetK]      = opcodes.GetKQ,
}

local status_code = {
    [0x0000] = "No error",
    [0x0001] = "Key not found",
    [0x0002] = "Key exists",
    [0x0003] = "Value too large",
    [0x0004] = "Invalid arguments",
    [0x0005] = "Item not stored",
    [0x0006] = "Incr/Decr on a non-numeric value",
    [0x0007] = "The vbucket belongs to another server",
    [0x0008] = "The connection is not connected to a bucket",
    [0x0009] = "The requested resource is locked",
    [0x000a] = "Stream not found for DCP message",
    [0x000b] = "The DCP message's opaque does not match the DCP stream's",
    [0x001f] = "The authentication context is stale, please re-authenticate",
    [0x0020] = "Authentication error",
    [0x0021] = "Authentication continue",
    [0x0022] = "The requested value is outside the legal ranges",
    [0x0023] = "Rollback required",
    [0x0024] = "No access",
    [0x0025] = "The node is being initialized",
    [0x0081] = "Unknown command",
    [0x0082] = "Out of memory",
    [0x0083] = "Not supported",
    [0x0084] = "Internal error",
    [0x0085] = "Busy",
    [0x0086] = "Temporary failure",
    [0x0087] = "XATTR invalid syntax",
    [0x0088] = "Unknown collection",
    [0x008a] = "Collections manifest not applied",
    [0x008c] = "Unknown scope",
    [0x008d] = "DCP stream ID is invalid",
    [0x00a0] = "Durability level invalid",
    [0x00a1] = "Durability impossible",
    [0x00a2] = "Synchronous write in progress",
    [0x00a3] = "Synchronous write ambiguous",
    [0x00a4] = "The SyncWrite is being re-committed after a change in active node",
    [0x00c0] = "(Subdoc) The provided path does not exist in the document",
    [0x00c1] = "(Subdoc) One of path components treats a non-dictionary as a dictionary, or a non-array as an array",
    [0x00c2] = "(Subdoc) The path’s syntax was incorrect",
    [0x00c3] = "(Subdoc) The path provided is too large; either the string is too long," ..
               " or it contains too many components",
    [0x00c4] = "(Subdoc) The document has too many levels to parse",
    [0x00c5] = "(Subdoc) The value provided will invalidate the JSON if inserted",
    [0x00c6] = "(Subdoc) The existing document is not valid JSON",
    [0x00c7] = "(Subdoc) The existing number is out of the valid range for arithmetic ops",
    [0x00c8] = "(Subdoc) The operation would result in a number outside the valid range",
    [0x00c9] = "(Subdoc) The requested operation requires the path to not already exist, but it exists",
    [0x00ca] = "(Subdoc) Inserting the value would cause the document to be too deep",
    [0x00cb] = "(Subdoc) An invalid combination of commands was specified",
    [0x00cc] = "(Subdoc) Specified key was successfully found, but one or more path operations failed. " ..
" Examine the individual lookup_result (MULTI_LOOKUP) / mutation_result (MULTI_MUTATION) structures for details.",
    [0x00cd] = "(Subdoc) Operation completed successfully on a deleted document",
    [0x00ce] = "(Subdoc) The flag combination doesn't make any sense",
    [0x00cf] = "(Subdoc) The key combination of the xattrs is not allowed",
    [0x00d0] = "(Subdoc) The server don't know about the specified macro",
    [0x00d1] = "(Subdoc) The server don't know about the specified virtual attribute",
    [0x00d2] = "(Subdoc) Can't modify virtual attributes",
    [0x00d3] = "(Subdoc) One or more paths in a multi-path command failed on a deleted document",
    [0x00d4] = "(Subdoc) Invalid XATTR order (xattrs should come first)",
    [0x00d5] = "(Subdoc) The server don't know this virtual macro",
    [0x00d6] = "(Subdoc) Only deleted documents can be revived",
    [0x00d7] = "(Subdoc) A deleted document can't have a value",
}


_M._unused_f2 = status_code


local data_types = {
    ["JSON"] = 0x01,
    ["Snappy compressed"] = 0x02,
    ["Extended attributes (XATTR)"] = 0x04
}


_M._unused_f3 = data_types


local function sasl_list(sock)

    local request_packet = packet_meta:create_request({
        opcode = opcodes.SASLList
    })

    local packet, err = prcess_sock_packet(sock, request_packet)
    if not packet then
        return nil, "failed to test hmac: " .. err
    end

    if strfind(packet.value, 'PLAIN') or strfind(packet.value, 'SCRAM_SHA') then
        return true
    end

    return nil, 'not support sasl'
end


local function sasl_auth(sock, client, auth_method)
    local value,nonce = nil

    auth_method = auth_method or "PLAIN"
    if auth_method == "SCRAM-SHA1" then
        local user = strgsub(strgsub(client.username, '=', '=3D'), ',' , '=2C')
        nonce = ngx_encode_base64(strsub(tostring(random()), 3 , 14))
        local first_bare = "n="  .. user .. ",r="  .. nonce
        value = "n,," .. first_bare
    end

    if auth_method == "PLAIN" then
        value = client.username .. strchar(0) .. client.password .. strchar(0)
    end

    local packet = packet_meta:create_request({
        opcode = opcodes.SASLAuth,
        key = auth_method,
        value = value
    })

    local sasl_packet, err = prcess_sock_packet(sock, packet)
    if not sasl_packet then
        return nil, "failed to get challenge: " .. err
    end

    return sasl_packet.value, "success", nonce
end


local function xor_bytestr(a, b )
    local res = ""

    for i=1,#a do
        res = res .. strchar(bxor(strbyte(a, i, i), strbyte(b, i, i)))
    end

    return res
end


local function pbkdf2_hmac_sha1( pbkdf2_key, iterations, salt, len )
    local u1 = ngx_hmac_sha1(pbkdf2_key, salt .. strchar(0) .. strchar(0) .. strchar(0) .. strchar(1))
    local ui = u1

    for i = 1, iterations - 1 do
        u1 = ngx_hmac_sha1(pbkdf2_key, u1)
        ui = xor_bytestr(ui, u1)
    end

    if #ui < len then
        for i = 1, len - (#ui) do
            ui = strchar(0) .. ui
        end
    end

    return ui
end


local function sasl_step(sock, client, auth_method, challenge, nonce)
    if auth_method == "PLAIN" then
        return nil, "error params"
    end

    local parsed_t = {}
    for k, v in strgmatch(challenge, "(%w+)=([^,]*)") do
        parsed_t[k] = v
    end

    local iterations = tonumber(parsed_t['i'])
    local salt = parsed_t['s']

    local rnonce = parsed_t['r']
    if not strsub(rnonce, 1, 12) == nonce then
        return nil, 'Server returned an invalid nonce.'
    end

    local without_proof = "c=biws,r=" .. rnonce
    -- local pbkdf2_key  = ngx_md5(client.username .. ":membercached:" .. client.password)
    local salted_pass = pbkdf2_hmac_sha1(client.password, iterations, ngx_decode_base64(salt), 20)
    local client_key  = ngx_hmac_sha1(salted_pass, "Client Key")
    local stored_key  = ngx_sha1_bin(client_key)

    local auth_msg    = "n="  .. client.username .. ",r=" .. nonce .. ',' .. challenge .. ',' .. without_proof
          auth_method = auth_method or 'SCRAM-SHA1'

    local client_sig = ngx_hmac_sha1(stored_key, auth_msg)
    local client_key_xor_sig = xor_bytestr(client_key, client_sig)
    local client_proof = "p=" .. ngx_encode_base64(client_key_xor_sig)
    local client_final = without_proof .. ',' .. client_proof

    local server_key = ngx_hmac_sha1(salted_pass, "Server Key")
    local server_sig = ngx_hmac_sha1(server_key, auth_msg)

    local packet = packet_meta:create_request({
        opcode = opcodes.SASLStep,
        key = auth_method,
        value = client_final
    })

    local step_packet, err = prcess_sock_packet(sock, packet)
    if not step_packet then
        return nil, "failed to do chanllenge: " .. err
    end

    challenge = step_packet.value
    parsed_t = {}
    for k, v in strgmatch(challenge, "(%w+)=([^,]*)") do
        parsed_t[k] = v
    end

    if parsed_t['v'] ~= ngx_encode_base64(server_sig) then
        return nil, "Server returned an invalid signature."
    end

    return (step_packet.value == 'Authenticated' or step_packet.value ~= 'Auth failure') or nil, step_packet.value
end

local function select_bucket(sock, client)
    if client.vbucket.name == client.vbucket.username then
        return true
    end

    local req_packet = packet_meta:create_request({
        opcode = opcodes.SelectBucket,
        key = client.vbucket.name,
        -- TODO suppot gzip.
        opaque = 0xefbeadde
    })

    local sele_packet, err = prcess_sock_packet(sock, req_packet)
    if not sele_packet then
        return nil, "failed to select_bucket: " .. tostring(err)
    end

    return sele_packet.value or sele_packet.status
end


local function get_pool_name(client, server)
    return server.host .. ':' .. server.port .. ':' .. client.vbucket.name
end


local function get_socks(client, pool_name)
    if not client.socks[pool_name] then
        local sock, err = ngx_socket_tcp()

        if not sock then
            return nil, err
        end

        sock:settimeout(default_timeout)
        client.socks[pool_name] = sock
    end

    return client.socks[pool_name]
end


local function create_connect(client, server)
    local pool_name = get_pool_name(client, server)
    local sock, err = get_socks(client, pool_name)
    if not sock then
        return nil, 'failed to create tcp: ' .. err
    end

    local ok, connect_err = sock:connect(server.host, server.port, { pool = pool_name })
    if not ok then
        return nil, 'failed to connect: ' .. connect_err
    end

    local reused = sock:getreusedtimes()
    if not (reused and reused > 0) then
        log_info('try to auth : host=', server.host, ', port=', server.port, ', bucket=', client.vbucket.name)

        local list, sasl_err = sasl_list(sock)
        if not list then
            log_info('get sasl_list failure : host=', server.host, ', port=', server.port,
                     ', bucket=', client.vbucket.name, "error: ",sasl_err)
            return nil, sasl_err
        end

        local challenge, auth_err, nonce = sasl_auth(sock, client, "SCRAM-SHA1")
        if not challenge then
            return nil, 'failed to sasl auth: ' .. auth_err
        end

        local has_auth, step_err = sasl_step(sock, client, "SCRAM-SHA1", challenge, nonce)
        if not has_auth then
            return nil, 'failed to sasl step: ' .. step_err
        end

        local has_sele, sele_err = select_bucket(sock, client)
        if not has_sele then
            return nil, 'failed to select bucket: ' .. sele_err
        end
    end

    return sock
end


local function group_packet_by_sock(client, packets)
    local vbucket = client.vbucket
    local socks, servers, errors = {}, {}, {}

    for _, packet in ipairs(packets) do
        local server = location_server(vbucket, packet)
        local sock = servers[server]

        if not sock and not errors[server] then
            local connect, err = create_connect(client, server)
            if not connect then

                if strfind(err, 'connection refused') then
                    log_info(err)
                    reload_vbucket(client.vbucket)
                end

                if strfind(err, 'no resolver defined to resolve') then
                    log_error(
                        'You need config nginx resolver. '
                        .. 'http://nginx.org/en/docs/http/ngx_http_core_module.html#resolver')
                end

                errors[#errors + 1] = { server = server, err = err }
            else
                sock = connect
                servers[server] = sock
                socks[sock] = {}
            end
        end

        if socks[sock] then
            local pks = socks[sock]
            pks[#pks + 1] = packet
        end
    end

    if #errors > 0 then
        log_info('group_packet_by_sock has some errors. errors=', cjson.encode(errors))
        return nil, cjson.encode(errors)
    end

    return socks
end


local function rewrite_packet(socks)
    for _, packets in pairs(socks) do
        if #packets > 1 then
            local last = #packets - 1
            for _ = 1, last, 1 do
                packet_meta.opcode = opcode_quiet[packet_meta.opcode]
            end
        end
    end
end


local function process_multi_packets(client, packets)
    local resps, errors = {}, {}
    local socks, err = group_packet_by_sock(client, packets)

    if not socks then
        log_error(" try group_packet_by_sock failure, error: ", err)
        return nil, err
    end

    rewrite_packet(socks)

    for sock, sock_packets in pairs(socks) do
        for _, packet in ipairs(sock_packets) do
            local bytes, send_err = packet:send_packet(sock)
            log_info("process_multi_packets bytes: ", bytes, ", send_err: ", send_err,
                     " packet: ", cjson.encode(packet))
            if not bytes then
                errors[packet] = send_err
            end
        end
    end

    for sock, sock_packets in pairs(socks) do
        for _, packet in ipairs(sock_packets) do
            if errors[packet] == nil then
                local resp, read_err = packet:read_packet(sock)
                log_info("process_multi_packets resp: ", cjson.encode(resp), ", read_err: ", read_err,
                         " packet: ", cjson.encode(packet))
                if not resp then
                    errors[packet] = read_err
                else
                    -- This is a common during rebalancing after adding or removing a node or during a failover.
                    if resp.status == 0x0007 then
                        reload_vbucket(client.vbucket)
                    end
                    resps[#resps + 1] = resp
                end
            end
        end
        sock:setkeepalive(pool_max_idle_timeout, pool_size)
    end

    if #errors > 0 then
        log_info('process_multi_packets has some errors. errors=', cjson.encode(errors))
    end

    return resps
end


local function process_packet(client, packet)

    local packets, err = process_multi_packets(client, { packet })

    if not (packets and packets[1]) then
        log_debug("try process_multi_packets failure. error: ", err, " packets: ", cjson.encode(packets))
        return nil, err
    end

    local resp = packets[1]
    if resp.status ~= 0x0 then
        log_debug("respone status error, ", err, ", data: ", cjson.encode(resp))
        return nil, resp.value
    end

    return resp.value or resp.status
end


local function n1ql_config(client)

    local n1ql_nodes = client.n1ql_nodes
    if #n1ql_nodes > 0 then
        return
    end

    local req_packet = packet_meta:create_request({
        opcode = opcodes.GetClusterConfig,
        key = '',
    })

    local value, err = process_packet(client, req_packet)
    if not value then
        return nil, "failed to get cluster config.: " .. err or ""
    end

    local config = cjson.decode(value)

    local nodes = config['nodesExt']
    for _, node in ipairs(nodes) do
        local services = node['services']
        if services.n1ql then
            n1ql_nodes[#n1ql_nodes + 1] = { node.hostname, services.n1ql }
        end
    end
end


local query_service = '/query/service'


local function query_n1ql(n1ql_nodes, n1ql, username, password)
    local token = ngx_encode_base64(username .. ':' .. password)

    local n1ql_node = n1ql_nodes[random(1, #n1ql_nodes)]
    local resp,err = http_post(n1ql_node[1], n1ql_node[2], query_service, {statement= n1ql},token)

    if not resp or err then
        return nil,err
    end

    return cjson.decode(resp)
end


function vbuckets:bucket(host_ports, bucket_name, username, password, cluster)
    local clustername = cluster or "default"
    local clu = vbuckets[clustername]

    if not clu then
        vbuckets[clustername] = {}
    end

    local vbucket = vbuckets[clustername][bucket_name]
    if not vbucket then
        local fetch_able = ngx_shared_ldict:safe_add(
            'couchbae_fetch_config' .. (ngx_crc32(tostring(ngx_ctx)) % 20
            + ngx_crc32(tostring(clustername)) % 20), 0, 1)

        if fetch_able then
            vbucket = create_vbucket(host_ports, bucket_name, username, password)
            if not vbucket then
                return nil, 'fail to build bucket'
            end
            vbuckets[clustername][bucket_name] = vbucket
        else
            ngx_sleep(0.5)
        end

        vbucket = vbuckets[clustername][bucket_name]
        if vbucket then
            return vbucket
        end
    end

    return vbucket
end


function _M:create_client(host_ports, bucket_name, username, password, cluster)
    local client = {
        vbucket = vbuckets:bucket(host_ports, bucket_name,
                                  username, password, cluster),
        socks = {},
        n1ql_nodes = {},
        username = username,
        password = password
    }

    if not client.vbucket then
        return nil, 'fail to create_client'
    end

    setmetatable(client, mt)
    return client
end


function _M:_get(opcode, key)
    local req_packet = packet_meta:create_request({
        opcode = opcode,
        key = key,
        -- data_type = data_type or 0x01
    })

    local value, err = process_packet(self, req_packet)
    if not value then
        return nil, "failed to get key: " .. tostring(err)
    end

    return value
end

function _M:get(key)
    return self:_get(opcodes.Get, key)
end

function _M:getq(key)
    return self:_get(opcodes.GetQ, key)
end

function _M:getk(key)
    return self:_get(opcodes.GetK, key)
end

function _M:getkq(key)
    return self:_get(opcodes.GetKQ, key)
end


function _M:get_from_replica(key)
    local req_packet = packet_meta:create_request({
        opcode = opcodes.GetFromReplica,
        key = key,
        is_replica = true,
    })

    local value, err = process_packet(self, req_packet)
    if not value then
        return nil, "failed to get key from replica: " .. tostring(err)
    end

    return value
end


function _M:hello()
    local req_packet = packet_meta:create_request({
        opcode = opcodes.Hello,
        key = "mchello v1.0",
        value = strchar(11)..strchar(0)
    })

    local ori_value, err = process_packet(self, req_packet)
    if not ori_value then
        return nil, "failed to set key: " .. tostring(err)
    end

    return ori_value
end

function _M:_set(opcode, key, value, expir, data_type)
    if type(value) == "table" then
        value = cjson.encode(value)
    end

    local req_packet = packet_meta:create_request({
        opcode = opcode,
        key = key,
        value = value,
        -- TODO suppot gzip.
        extra = extra_data(0x0, expir or 0x0)
    })

    local ori_value, err = process_packet(self, req_packet)
    if not ori_value then
        return nil, "failed to ".. opcode .." key: " .. tostring(err)
    end

    return ori_value
end

function _M:set(key, value, expir, data_type)
    return self:_set(opcodes.Set, key, value, expir, data_type)
end

function _M:setq(key, value, expir, data_type)
    return self:_set(opcodes.SetQ, key, value, expir, data_type)
end

function _M:add(key, value, expir, data_type)
    return self:_set(opcodes.Add, key, value, expir, data_type)
end

function _M:addq(key, value, expir, data_type)
    return self:_set(opcodes.AddQ, key, value, expir, data_type)
end

function _M:replace(key, value, expir, data_type)
    return self:_set(opcodes.Replace, key, value, expir, data_type)
end

function _M:replaceq(key, value, expir, data_type)
    return self:_set(opcodes.ReplaceQ, key, value, expir, data_type)
end

function _M:_delete(opcode, key)
    local req_packet = packet_meta:create_request({
        opcode = opcode,
        key = key,
    })

    local value, err = process_packet(self, req_packet)
    if not value then
        return nil, "failed to delete ".. opcode .." key: " .. tostring(err)
    end

    return value
end

function _M:delete(key)
    return self:_delete(opcodes.Delete, key)
end


function _M:deleteq(key)
    return self:_delete(opcodes.DeleteQ, key)
end

function _M:get_bluk(...)
    local resp_values = {}
    local req_packets = {}

    for _, key in ipairs({ ... }) do
        req_packets[#req_packets + 1] = packet_meta:create_request({
            opcode = opcodes.Get,
            key = key,
        })
    end

    local resp_packets, err = process_multi_packets(self, req_packets)

    if not resp_packets then
        return nil, "failed to get_bluk: " .. tostring(err)
    end

    for _, packet in ipairs(resp_packets) do
        if packet.status == 0x0 then
            resp_values[packet.key] = packet.value
        end
    end

    return resp_values
end

function _M:select_bucket(bucket_name)
    local req_packet = packet_meta:create_request({
        opcode = opcodes.SelectBucket,
        key = bucket_name,
        -- TODO suppot gzip.
        opaque = 0xefbeadde
    })

    local ori_value, err = process_packet(self, req_packet)
    if not ori_value then
        return nil, "failed to select_bucket: " .. tostring(err)
    end

    return ori_value
end


function _M:query(n1ql)

    n1ql_config(self)

    local n1ql_nodes = self.n1ql_nodes
    if #n1ql_nodes == 0 then
        return nil, 'server is not support the N1QL.'
    end

    local value, err = query_n1ql(n1ql_nodes, n1ql,self.username, self.password)
    if value then
        return value.results
    end

    return nil, err
end


function _M:set_timeout(timeout)
    local socks = self.socks
    for _, sock in pairs(socks) do
        sock:settimeout(timeout)
    end
end


function _M:close()
    local socks = self.socks

    for _, sock in pairs(socks) do
        sock:close()
    end
end


return _M
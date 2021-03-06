local setmetatable = setmetatable
local next = next
local open = io.open
local gmatch = string.gmatch
local match = string.match
local format = string.format
local insert = table.insert
local getenv = os.getenv
local concat = table.concat
local io_type = io.type
local re_match = ngx.re.match
local resolver_cache = require 'resty.resolver.cache'
local dns_client = require 'resty.resolver.dns_client'
local re = require('ngx.re')
local semaphore = require "ngx.semaphore"
local synchronization = require('resty.synchronization').new(1)

local init = semaphore.new(1)

local default_resolver_port = 53

local _M = {
  _VERSION = '0.1',
  _nameservers = {},
  search = { '' }
}

local mt = { __index = _M }

local function read_resolv_conf(path)
  path = path or '/etc/resolv.conf'

  local handle, err

  if io_type(path) then
    handle = path
  else
    handle, err = open(path)
  end

  local output

  if handle then
    handle:seek("set")
    output = handle:read("*a")
    handle:close()
  end

  return output or "", err
end

function _M.parse_nameservers(path)
  local resolv_conf, err = read_resolv_conf(path)

  if err then
    ngx.log(ngx.WARN, 'resolver could not get nameservers: ', err)
  end

  ngx.log(ngx.DEBUG, '/etc/resolv.conf:\n', resolv_conf)

  local search = { '' }
  local nameservers = { search = search }
  local resolver = getenv('RESOLVER')
  local domains = match(resolv_conf, 'search%s+([^\n]+)')

  ngx.log(ngx.DEBUG, 'search ', domains)
  for domain in gmatch(domains or '', '([^%s]+)') do
    ngx.log(ngx.DEBUG, 'search domain: ', domain)
    insert(search, domain)
  end

  if resolver then
    local m = re.split(resolver, ':', 'oj')
    insert(nameservers, { m[1] , m[2] or default_resolver_port })
    return nameservers
  end

  for nameserver in gmatch(resolv_conf, 'nameserver%s+([^%s]+)') do
    -- TODO: implement port matching based on https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=549190
    if nameserver ~= resolver then
      insert(nameservers, { nameserver, default_resolver_port } )
    end
  end

  return nameservers
end

function _M.init_nameservers()
  local nameservers = _M.parse_nameservers() or {}
  local search = nameservers.search or {}

  for i=1, #nameservers do
    ngx.log(ngx.INFO, 'adding ', nameservers[i][1],':', nameservers[i][2], ' as default nameserver')
    insert(_M._nameservers, nameservers[i])
  end

  for i=1, #search do
    ngx.log(ngx.INFO, 'adding ', search[i], ' as search domain')
    insert(_M.search, search[i])
  end
end

function _M.nameservers()
  local ok, _ = init:wait(0)

  if ok and #(_M._nameservers) == 0 then
    _M.init()
  end

  if ok then
    init:post()
  end

  return _M._nameservers
end

function _M.init()
  _M.init_nameservers()
end

function _M.new(dns, opts)
  opts = opts or {}
  local cache = opts.cache or resolver_cache.new()
  local search = opts.search or _M.search

  ngx.log(ngx.DEBUG, 'resolver search domains: ', concat(search, ' '))

  return setmetatable({
    dns = dns,
    options = { qtype = dns.TYPE_A },
    cache = cache,
    search = search
  }, mt)
end

function _M:instance()
  local ctx = ngx.ctx
  local resolver = ctx.resolver

  if not resolver then
    local dns = dns_client:instance(self.nameservers())
    resolver = self.new(dns)
    ctx.resolver = resolver
  end

  return resolver
end

local function new_server(answer, port)
  if not answer then return nil, 'missing answer' end
  local address = answer.address
  if not address then return nil, 'server missing address' end

  return {
    address = answer.address,
    ttl = answer.ttl,
    port = answer.port or port
  }
end

local function new_answer(address, port)
  return {
    address = address,
    ttl = -1,
    port = port
  }
end

local function is_ip(address)
  local m, err = re_match(address, '^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$', 'oj')

  if m then
    return next(m)
  else
    return nil, err
  end
end

local function convert_answers(answers, port)
  local servers = {}

  for i=1, #answers do
    servers[#servers+1] = new_server(answers[i], port)
  end

  servers.answers = answers

  return servers
end

local empty = {}

local function lookup(dns, qname, search, options)
  ngx.log(ngx.DEBUG, 'resolver query: ', qname)

  local answers, err

  if is_ip(qname) then
    ngx.log(ngx.DEBUG, 'host is ip address: ', qname)
    answers = { new_answer(qname) }
  else
    for i=1, #search do
      local query = qname .. '.' .. search[i]
      ngx.log(ngx.DEBUG, 'resolver query: ', qname, ' search: ', search[i], ' query: ', query)
      answers, err = dns:query(query, options)

      if answers and not answers.errcode and #answers > 0 then
        break
      end
    end
  end

  ngx.log(ngx.DEBUG, 'resolver query: ', qname, ' finished with ', #(answers or empty), ' answers')
  return answers, err
end

function _M.get_servers(self, qname, opts)
  opts = opts or {}
  local dns = self.dns

  if not dns then
    return nil, 'resolver not initialized'
  end

  if not qname then
    return nil, 'query missing'
  end

  local cache = self.cache
  local search = self.search or _M.search

  -- TODO: pass proper options to dns resolver (like SRV query type)

  local sema, key = synchronization:acquire(format('qname:%s:qtype:%s', qname, 'A'))
  local ok = sema:wait(0)

  local answers, err = cache:get(qname, not ok)

  if not answers or err or #answers.addresses == 0 then
    answers, err = lookup(dns, qname, search, self.options)
    cache:save(answers)
  end

  if ok then
    -- cleanup the key so we don't have unbounded growth of this table
    synchronization:release(key)
    sema:post()
  end

  if err then
    ngx.log(ngx.DEBUG, 'query for ', qname, ' finished with error: ', err)
    return {}, err
  end

  if not answers then
    ngx.log(ngx.DEBUG, 'query for ', qname, ' finished with no answers')
    return {}, 'no answers'
  end

  ngx.log(ngx.DEBUG, 'query for ', qname, ' finished with ' , #answers, ' answers')

  local servers = convert_answers(answers, opts.port)

  servers.query = qname

  return servers
end

return _M

exports.name = "creationix/weblit-app"
exports.version = "0.2.5-1"
exports.dependencies = {
  'creationix/coro-wrapper@1.0.0',
  'creationix/coro-tcp@1.0.5',
  'creationix/coro-tls@1.1.3',
  'luvit/http-codec@1.0.0',
  'luvit/querystring@1.0.0',
}
exports.description = "Weblit is a webapp framework designed around routes and middleware layers."
exports.tags = {"weblit", "router", "framework"}
exports.license = "MIT"
exports.author = { name = "Tim Caswell" }
exports.homepage = "https://github.com/creationix/weblit/blob/master/libs/weblit-app.lua"

--[[
Web App Framework

Middleware Contract:

function middleware(req, res, go)
  req.method
  req.path
  req.params
  req.headers
  req.version
  req.keepAlive
  req.body

  res.code
  res.headers
  res.body

  go() - Run next in chain, can tail call or wait for return and do more

headers is a table/list with numerical headers.  But you can also read and
write headers using string keys, it will do case-insensitive compare for you.

body can be a string or a stream.  A stream is nothing more than a function
you can call repeatedly to get new values.  Returns nil when done.

server
  .bind({
    host = "0.0.0.0",
    port = 8080
  })
  .bind({
    host = "0.0.0.0",
    port = 8443,
    tls = {
      cert = certString,
      key = keyString,
    }
  })
  .route({
    method = "GET",
    host = "^creationix.com",
    path = "/:path:"
  }, middleware)
  .use(middleware)
  .start()
]]

local createServer = require('coro-tcp').createServer
local wrapper = require('coro-wrapper')
local readWrap, writeWrap = wrapper.reader, wrapper.writer
local httpCodec = require('http-codec')
local tlsWrap = require('coro-tls').wrap
local parseQuery = require('querystring').parse

local server = {}
local handlers = {}
local bindings = {}

-- Provide a nice case insensitive interface to headers.
local headerMeta = {
  __index = function (list, name)
    if type(name) ~= "string" then
      return rawget(list, name)
    end
    name = name:lower()
    for i = 1, #list do
      local key, value = unpack(list[i])
      if key:lower() == name then return value end
    end
  end,
  __newindex = function (list, name, value)
    if type(name) ~= "string" then
      return rawset(list, name, value)
    end
    local lowerName = name:lower()
    for i = 1, #list do
      local key = list[i][1]
      if key:lower() == lowerName then
        if value == nil then
          table.remove(list, i)
        else
          list[i] = {name, tostring(value)}
        end
        return
      end
    end
    if value == nil then return end
    rawset(list, #list + 1, {name, tostring(value)})
  end,
}

local function handleRequest(head, input, socket)
  local req = {
    socket = socket,
    method = head.method,
    path = head.path,
    headers = setmetatable({}, headerMeta),
    version = head.version,
    keepAlive = head.keepAlive,
    body = input
  }
  for i = 1, #head do
    req.headers[i] = head[i]
  end

  local res = {
    code = 404,
    headers = setmetatable({}, headerMeta),
    body = "Not Found\n",
  }

  local function run(i)
    local success, err = pcall(function ()
      i = i or 1
      local go = i < #handlers
        and function ()
          return run(i + 1)
        end
        or function () end
      return handlers[i](req, res, go)
    end)
    if not success then
      res.code = 500
      res.headers = setmetatable({}, headerMeta)
      res.body = err
      print(err)
    end
  end
  run(1)

  local out = {
    code = res.code,
    keepAlive = res.keepAlive,
  }
  for i = 1, #res.headers do
    out[i] = res.headers[i]
  end
  return out, res.body, res.upgrade
end

local function handleConnection(rawRead, rawWrite, socket)

  -- Speak in HTTP events
  local read, updateDecoder = readWrap(rawRead, httpCodec.decoder())
  local write, updateEncoder = writeWrap(rawWrite, httpCodec.encoder())

  for head in read do
    local parts = {}
    for chunk in read do
      if #chunk > 0 then
        parts[#parts + 1] = chunk
      else
        break
      end
    end
    local res, body, upgrade = handleRequest(head, #parts > 0 and table.concat(parts) or nil, socket)
    write(res)
    if upgrade then
      return upgrade(read, write, updateDecoder, updateEncoder, socket)
    end
    write(body)
    if not (res.keepAlive and head.keepAlive) then
      break
    end
  end
  write()

end

function server.bind(options)
  if not options.host then
    options.host = "127.0.0.1"
  end
  if not options.port then
    options.port = require('uv').getuid() == 0 and
      (options.tls and 443 or 80) or
      (options.tls and 8443 or 8080)
  end
  bindings[#bindings + 1] = options
  return server
end

function server.use(handler)
  handlers[#handlers + 1] = handler
  return server
end


function server.start()
  if #bindings == 0 then
    server.bind({})
  end
  for i = 1, #bindings do
    local options = bindings[i]
    createServer(options.host, options.port, function (rawRead, rawWrite, socket)
      local tls = options.tls
      if tls then
        rawRead, rawWrite = tlsWrap(rawRead, rawWrite, {
          server = true,
          key = assert(tls.key, "tls key required"),
          cert = assert(tls.cert, "tls cert required"),
        })
      end
      return handleConnection(rawRead, rawWrite, socket)
    end)
    print("HTTP server listening at http" .. (options.tls and "s" or "") .. "://" .. options.host .. (options.port == (options.tls and 443 or 80) and "" or ":" .. options.port) .. "/")
  end
  return server
end

local quotepattern = '(['..("%^$().[]*+-?"):gsub("(.)", "%%%1")..'])'
local function escape(str)
    return str:gsub(quotepattern, "%%%1")
end

local function compileGlob(glob)
  local parts = {"^"}
  for a, b in glob:gmatch("([^*]*)(%**)") do
    if #a > 0 then
      parts[#parts + 1] = escape(a)
    end
    if #b > 0 then
      parts[#parts + 1] = "(.*)"
    end
  end
  parts[#parts + 1] = "$"
  local pattern = table.concat(parts)
  return function (string)
    return string and string:match(pattern)
  end
end

local function compileRoute(route)
  local parts = {"^"}
  local names = {}
  for a, b, c, d in route:gmatch("([^:]*):([_%a][_%w]*)(:?)([^:]*)") do
    if #a > 0 then
      parts[#parts + 1] = escape(a)
    end
    if #c > 0 then
      parts[#parts + 1] = "(.*)"
    else
      parts[#parts + 1] = "([^/]*)"
    end
    names[#names + 1] = b
    if #d > 0 then
      parts[#parts + 1] = escape(d)
    end
  end
  if #parts == 1 then
    return function (string)
      if string == route then return {} end
    end
  end
  parts[#parts + 1] = "$"
  local pattern = table.concat(parts)
  return function (string)
    local matches = {string:match(pattern)}
    if #matches > 0 then
      local results = {}
      for i = 1, #matches do
        results[i] = matches[i]
        results[names[i]] = matches[i]
      end
      return results
    end
  end
end

function server.route(options, handler)
  local method = options.method
  local path = options.path and compileRoute(options.path)
  local host = options.host and compileGlob(options.host)
  local filter = options.filter
  server.use(function (req, res, go)
    if method and req.method ~= method then return go() end
    if host and not host(req.headers.host) then return go() end
    if filter and not filter(req) then return go() end
    local params
    if path then
      local pathname, query = req.path:match("^([^?]*)%??(.*)")
      params = path(pathname)
      if not params then return go() end
      if #query > 0 then
        req.query = parseQuery(query)
      end
    end
    req.params = params or {}
    return handler(req, res, go)
  end)
  return server
end

return server

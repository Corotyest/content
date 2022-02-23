--[[lit-meta
	name = 'Corotyest/content'
	version = '0.2.2-2-beta'
	dependencies = { 'Corotyest/lua-extensions', 'Corotyest/inspect' }
]]

local inspect = require 'inspect'
local extensions = require 'lua-extensions'(true)
local string, table = extensions.string, extensions.table

local getudata, setudata = debug.getuservalue, debug.setuservalue
local f_type, open, close = io.type, io.open, io.close
local remove, execute = os.remove, os.execute
local format, sfind, match, _split, sinsert = string.format, string.find, string.match, string.split, string.sinsert
local concat = table.concat
local _error = 'incorrect argument #%s for %s (%s expected got %s)'

local haswindows = jit and jit.arch == 'Windows' or package.path:match('\\') and true
local prefix = haswindows and '\\' or '/'

local function split(value)
	local type1 = type(value)
	if type1 ~= 'string' then
		return nil, format(_error, 1, 'split', 'string', type1)
	end

	-- different matchs for get correct values
	local path = sfind(value, '/', 1, true); path = path and path ~= 1 and match(value, '(.*)/.*$') or nil
	local filename = path and match(value, '.*/(.-)$') or value

	return path and match(path, '%g*'), filename, match(filename, '.*%.(.-)$')
end

local function attach(path, ...)
	local type1 = type(path)
	if type1 ~= 'string' then
		return nil, format(_error, 1, 'attach', 'string', type1)
	end

	local has = sfind(path, '/', 1, true) ~= 1
	path = has and concat(_split(path, '/'), prefix) or path

	local response = { path }
	if ... then
		for index = 1, select('#', ...) do
			response[#response + 1] = select(index, ...)
		end
	end

	return concat(response, prefix)
end

local function edit_dir(self, path, deldir)
	local type1, type2 , type3 = type(self), type(path), type(deldir)
	if type1 ~= 'table' then
		return nil, format(_error, 'self', 'edit_dir', type1)
	elseif type2 ~= 'string' then
		return nil, format(_error, 1, 'edit_dir', 'string', type2)
	elseif deldir and type3 ~= 'boolean' then
		return nil, format(_error, 2, 'edit_dir', 'boolean', type3)
	end

	local path = attach(path)

	if path and #path ~= 0 then
		local endpoint = format(self.request, path, prefix)
		local response = open(endpoint, 'w')

		if not response then
			return execute(format('mkdir %s', path)) and true, 'new'
		else
			close(response); remove(endpoint)
			return deldir and execute(format('rmdir %s', path)) or not deldir and true, 'del'
		end
	end
end

local function isFile(file)
	local type1 = type(file)
	if type1 ~= 'userdata' then
		return false
	end

	return f_type(file) ~= nil or sfind(tostring(file), 'file', 1, true) == 1
end

local function file_info(file, data)
	local type1 = type(file)
	if not isFile(file) then
		return nil, format(_error, 1, 'file_info', 'userdata', type1)
	end

	data = type(data) == 'table' and data or { __name = data }

	local userdata = getudata(file)

	for key, value in pairs(data) do
		if sfind(key, '__', 1, true) ~= 1 then
			error('cannot damage userdata integrity')
		end
		userdata[key] = value
	end

	return setudata(file, userdata, '__index')
end

local handles = { }
local _handle = { }

function _handle.open(self, filename)
	filename = filename or self.filename

	local input = open(filename, 'r')
	file_info(input, filename)

	self.handle.input = input
	self.handle.output = {
		write = function(self, ...)
			local file = open(filename, 'w')
			local success, error = pcall(file.write, file, ...); file:close()

			if success then
				return success
			else
				return nil, error
			end
		end,
		__name = filename
	}

	return self
end

function _handle.close(self)
	return self.handle.input:close()
end

function _handle.content(self, ...)
	local file = self.handle.input

	local lines = { }
	for line in file:lines() do
		lines[#lines + 1] = line
	end
	
	local data = concat(lines, '\n')
	local success, chunck = pcall(load(data, file.__name, nil, _G), ...)

	return success and chunck or data
end

function _handle.write(self, options, ...)
	local file = self.handle.output

	local type1 = type(options)
	local setret = type1 == 'table' and options.setret

	local base = {...}
	if type1 ~= 'table' then table.insert(base, 1, options) end

	return file:write(self.extension == 'lua' and setret and 'return ' or '', unpack(base))
end

function _handle.apply(self, options)
	local key, value = options.key, options.value

	local module = self:content()

	if type(module) == 'table' then
		if key then
			local response = type(key) == 'string' and sinsert(module, key, value)

			if not response then
				module[key] = value
			end
		else
			module[#module + 1] = value
		end
	else
		module = value
	end

	return self:write(inspect(module))
end

local _remove = remove

function _handle.remove(self)
	local filename = self.filename
	self:close(); handles[self] = nil; return _remove(filename)
end

local info = debug.getinfo

local function newHandle(self, file)
	local type1, type2 = type(self), type(file)
	if type1 ~= 'table' then
		return nil, format(_error, 'self', 'neHandle', 'table', type1)
	elseif type2 ~= 'string' then
		if not self.isFile(file) then
			return nil, format(_error, 1, 'newHandle', 'string/userdata', type2)
		end
	end

	local pathname, filename, extension = self.split(file)

	if extension ~= 'lua' then return error('currently only supporting lua files', 2) end

	local meta = { }
	local props = {
		handle = { },
		pathname = pathname,
		filename = filename,
		extension = extension,
	}

	function meta.__pairs()
		return next, _handle, nil
	end

	function meta.__index(self, k)
		if not handles[self] then return error('this handle is removed', 2) end

		local value = rawget(_handle, k)
		if type(value) == 'function' then
			return function(self, ...)
				local type1 = type(self)
				if type1 ~= 'table' then
					return nil, format(_error, 'self', k, 'table', type1)
				end
				return value(self, ...)
			end
		else
			return props[k]
		end
	end

	function meta.__newindex(self, k, v)
		local _info = info(2)

		local _, name = split(_info.source)
		if name ~= 'content.lua' then
			return error('attempt to index a protected table', 2)
		end

		return rawset(props, k, v)
	end

	function meta.__tostring(self)
		return self.filename
	end

	local handle = setmetatable({}, meta)

	handles[handle] = true
	return handle:open()
end

local function isHandle(handle)
	return handles[handle]
end

return {
	split = split,
	isFile = isFile,
	attach = attach,
	prefix = prefix,
	request = '%s%srequest',
	isHandle = isHandle,
	edit_dir = edit_dir,
	file_info = file_info,
	newHandle = newHandle,
	haswindows = haswindows,
}
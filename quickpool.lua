local obj = require('obj')
local fiber = require('fiber')
local log = require('log')
local remote = require('net.box')

local pool = obj.class({},'pool')

function pool:_init(cfg)
	local zones = {}
	self.total = 0
	self.timeout = self.timeout or 1
	for _,srv in ipairs(cfg.servers) do
		local login = srv.login or cfg.login
		local password = srv.password or cfg.password
		local uri = login .. ':' .. password .. '@' .. srv.uri
		local zid = srv.zone or cfg.zone or 'default'
		local node = {
			peer = srv.uri,
			uri  = uri,
			zone = zid,
			state = 'inactive',
		}
		if not zones[zid] then
			zones[zid] = {
				id       = zid,
				total    = 0,
				active   = {}, -- active and responsive connected nodes
				inactive = {}, -- disconnected nodes
				deferred = {}, -- tcp connected but unresponsive nodes
			}
		end

		local zone = zones[zid]
		zone.total = zone.total + 1
		self.total = self.total + 1
		table.insert(zone.inactive,node)
	end
	self.zones = zones
	self.name = cfg.name or 'default'
end

function pool:counts()
	if self._counts then return self._counts end
	local active   = 0
	local inactive = 0
	local deferred = 0

	for _,z in pairs(self.zones) do
		active   = active   + #z.active
		inactive = inactive + #z.inactive
		deferred = deferred + #z.deferred
	end
	self._counts = {
		active   = active;
		inactive = inactive;
		deferred = deferred;
	}
	return self._counts
end

function pool:_move_node(zone,node,state1,state2)
	local found = false
	log.info("move node %s from %s to %s", node.peer, state1, state2)
	for _,v in pairs(zone[state1]) do
		if v == node then
			table.remove(zone[state1],_)
			found = true
			break
		end
	end
	if not found then
		log.error("Node %s not dound in state %s.",node.peer,state1)
	end
	table.insert(zone[state2],node)
	node.state = state2
end

function pool:node_state_change(zone,node,state)
	local prevstate = node.state
	self._counts = nil

	if state == 'active' then
		self:_move_node(zone,node,prevstate,state)

		self:on_connected_one(node)

		if #zone.active == zone.total then
			self:on_connected_zone(zone)
		end

		if self:counts().active == self.total then
			self:on_connected()
		end
	else -- deferred or inactive
		self:_move_node(zone,node,prevstate,state)
		-- moving from deferred to inactive we don't alert with callbacks
		if prevstate == 'active' then
			self:on_disconnect_one(node)

			if #zone.active == 0 then
				self:on_disconnect_zone(zone)
			end

			if self:counts().active == 0 then
				self:on_disconnect()
			end
		end
	end
end

function pool:connect()
	if self.__connecting then return end
	self.__connecting = true
	self:on_init()
	for zid,zone in pairs(self.zones) do
		for _,node in pairs(zone.inactive) do
			fiber.create(function()
				fiber.name(self.name..':'..node.peer)
				node.conn = remote:new( node.uri, { reconnect_after = 1/3, timeout = 1 } )
				local state
				local conn_generation = 0
				while true do
					state = node.conn:_wait_state({active = true})

					local r,e = pcall(node.conn.eval,node.conn,"return box.info")
					if r and e then
						local uuid = e.server.uuid
						if node.uuid and uuid ~= node.uuid then
							log.warn("server %s changed it's uuid %s -> %s",node.peer,node.uuid,uuid)
						end
						node.uuid = uuid
						conn_generation = conn_generation + 1

						--- TODO: if self then ...

						log.info("connected %s, uuid = %s",node.peer,uuid)
						self:node_state_change(zone,node,'active')

						--- start pinger
						fiber.create(function()
							local gen = conn_generation
							local last_state_ok = true
							while gen == conn_generation do
								--- TODO: replace ping with node status (rw/ro)
								local r,e = pcall(node.conn.ping,node.conn:timeout(self.timeout))
								if r and e then
									if not last_state_ok and gen == conn_generation then
										log.info("node %s become online by ping",node.peer)
										last_state_ok = true
										self:node_state_change(zone,node,'active')
									end
								else
									if last_state_ok and gen == conn_generation then
										log.warn("node %s become offline by ping: %s",node.peer,e)
										last_state_ok = false
										self:node_state_change(zone,node,'deferred')
									end
								end
								fiber.sleep(1)
							end
						end)

						state = node.conn:_wait_state({error = true, closed = true})
						self:node_state_change(zone,node,'inactive')

					else
						log.warn("uuid request failed for %s: %s",node.peer,e)
					end
				end

			end)
		end
	end
	--
end

function pool:on_connected_one (node)
	log.info('on_connected_one %s : %s',node.peer,node.uuid)
end

function pool:on_connected_zone (zone)
	log.info('on_connected_zone %s',zone.id)
end

function pool:on_connected ()
	log.info('on_connected all')
end

function pool:on_connfail( node )
	log.info('on_connfail ???')
end

function pool:on_disconnect_one (node)
	log.info('on_disconnect_one %s : %s',node.peer,node.uuid)
end

function pool:on_disconnect_zone (zone)
	log.info('on_disconnect_zone %s',zone.id)
end

function pool:on_disconnect ()
	log.info('on_disconnect all')
end

function pool:on_init ()
end

function pool.heartbeat()
	local self = _G['pool']
	-- ...
end

_G['pool'] = pool
return pool
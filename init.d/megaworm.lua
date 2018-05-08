--- COPYRIGHT ---
-- Copyright (c) 2018 James H. Gilles
-- 
-- This software is provided 'as-is', without any express or implied
-- warranty. In no event will the authors be held liable for any damages
-- arising from the use of this software.
-- 
-- Permission is granted to anyone to use this software for any purpose,
-- including commercial applications, and to alter it and redistribute it
-- freely, subject to the following restrictions:
-- 
-- 1. The origin of this software must not be misrepresented; you must not
--    claim that you wrote the original software. If you use this software
--    in a product, an acknowledgment in the product documentation would be
--    appreciated but is not required.
-- 2. Altered source versions must be plainly marked as such, and must not be
--    misrepresented as being the original software.
-- 3. This notice may not be removed or altered from any source distribution.

--- README ---
-- This script handles making megaworms behave correctly in-game.
-- Lots of horrible hacks, hooray!
-- Segments are "coded as minions", they're just additional units that get teleported around.

-- http://www.bay12forums.com/smf/index.php?topic=164123.msg7738016#msg7738016

--- TODO ---
-- Are IDs persistent?
-- Figure out some way to make the segments not attack / run away from each other

--- IMPORTS ---
local repeat_util = require('repeat-util')

--- CONFIGURATION ---
local CHECK_EVERY = 200
local DEBUG = true

--- DATA ---
-- int:creature_raw
-- used for unit checks
local species = {}

-- the actual worms
-- id:{ head: unit, segments: unit[], positions: {x,y,z}[] }
local worms = {}

--- LIFECYCLE ---
function onStateChange(op)
    -- SC_WORLD_LOADED, SC_WORLD_UNLOADED, SC_MAP_LOADED, SC_MAP_UNLOADED, SC_VIEWSCREEN_CHANGED, SC_CORE_INITIALIZED
    if op == SC_MAP_LOADED then
        debug("map loaded")
        scanRaws()
        repeat_util.scheduleUnlessAlreadyScheduled(
            "megaworm_main_loop",
            1, 'ticks',
            mainLoop
        )
    end
end

local i = 0
function mainLoop()
    if i == 100 then
        i = 0
        scanHeads()
    end
    i = i + 1
    if not empty(worms) then
        dfhack.with_suspend(mainLoopInner)
    end
end

function mainLoopInner()
    for id, worm in pairs(worms) do
        -- TODO persist worm.has_segments so that heads don't regrow on save
        if not worm.has_segments then
            local foundExisting = collectClaimedSegments(worm)
            if not foundExisting then
                spawnSegments(worm)
                collectUnclaimedSegments(worm)
            end
            collateSegments(worm)
            worm.has_segments = true
            for i = 0,#worm.segments do
                worm:getPortion(i).enemy.enemy_status_slot = -1
            end
            for i = 1,#worm.segments do
                worm:getPortion(i).following = worm:getPortion(i-1)
            end
        end
        stopFightingYouFucks(worm)
        moveSegments(worm)
    end
end

function onUnload()
    debug("unload")
end

--- UTILITY ---
function teleport(unit, pos)
    local unitoccupancy = dfhack.maps.getTileBlock(unit.pos).occupancy[unit.pos.x%16][unit.pos.y%16]
    local newoccupancy = dfhack.maps.getTileBlock(pos).occupancy[pos.x%16][pos.y%16]
    --if newoccupancy.unit then
    --    unit.flags1.on_ground = true
    --end
    unit.pos.x = pos.x
    unit.pos.y = pos.y
    unit.pos.z = pos.z
    if not unit.flags1.on_ground then unitoccupancy.unit = false else unitoccupancy.unit_grounded = false end
end

function string.ends(s,e)
    return e=='' or string.sub(s,-string.len(e))==e
end

function empty(t)
    for _ in pairs(t) do
        return false
    end
    return true
end

function debug(...)
    print('megaworm debug: ', ...)
end

function isReachable(pos1, pos2)
    local dx = pos1.x - pos2.x
    local dy = pos1.y - pos2.y
    local dz = pos1.z - pos2.z
    return math.abs(dx) <= 1 and math.abs(dy) <= 1 and math.abs(dz) <= 1
end

function clonePosition(pos)
    return {x=pos.x, y=pos.y, z=pos.z}
end
function positionEquals(pos_a, pos_b)
    return pos_a.x == pos_b.x and pos_a.y == pos_b.y and pos_a.z == pos_b.z
end

local Worm = {}
local Worm_mt = { __index = Worm }
function Worm.new(head)
    local result = {
        head = head,
        segments_created = false,
        segments = {},
        last_head_pos = clonePosition(head.pos),
        ids = {} -- set
    }
    result.ids[head.id] = true
    setmetatable(result, Worm_mt)
    return result
end
function Worm.getPortion(worm, i)
    if i == 0 then
        return worm.head
    else
        return worm.segments[i]
    end
end
function Worm.addSegment(worm, segment)
    table.insert(worm.segments, segment)
    worm.ids[segment.id] = true
end

--- INITIALIZATION ---
-- search for worms in the raws
-- occurs at map load
-- "worm" species have MEGAWORM_HEAD as a suffix of their id
function scanRaws()
    debug('scanRaws')
    local creatures = df.global.world.raws.creatures.all
    for id, creature in ipairs(creatures) do
        if string.ends(creature.creature_id, '_MEGAWORM') then
            species[id] = {}
            species[id].creature_raw = creature
            species[id].head_caste_raw = creature.caste[0]
            species[id].segment_caste_raw = creature.caste[1]
            debug('found species:', id, species[id].creature_raw.creature_id)
            debug('head caste:', species[id].head_caste_raw.caste_id)
            debug('segment caste:', species[id].segment_caste_raw.caste_id)
        end
    end
end

-- Search for megaworms; run periodically
function scanHeads()
    local units = df.global.world.units.all
    debug('scanheads')
    for i,unit in ipairs(units) do
        if species[unit.race] ~= nil and unit.caste == 0 and not unit.flags1.dead then
            if worms[unit.id] == nil then
                debug("new worm head!", i, unit.name.first_name)
                worms[unit.id] = Worm.new(unit)
                debug(worms[unit.id])
            end
        end
    end
end

-- Create fresh worm segments
function spawnSegments(worm)
    -- TODO from raws
    local n = 10
    local spec = species[worm.head.race]
    local pos = worm.head.pos

    for i=1,n do
        debug('making segment', i)
        -- lol
        -- this is the best way to do this i can figure out, tbh
        dfhack.run_script('modtools/create-unit',
            '-race', spec.creature_raw.creature_id,
            '-caste', spec.segment_caste_raw.caste_id,
            --'-domesticate',
            --'-setUnitToFort',
            '-location', '[', pos.x + i * 3, pos.y, pos.z, ']',
            '-flagSet', '[', ']'
        )
    end
end

-- Locate segments already attached to this worm; return whether or not we found them.
function collectClaimedSegments(worm)
    debug('collecting claimed segments for', worm.id)
    local n = 10
    local race = worm.head.race
    local units = df.global.world.units.all
    local thisWorm = {}

    for i,unit in ipairs(units) do
        if unit.race == race and unit.caste == 1 and not unit.flags1.dead then
            local entry = dfhack.persistent.get(string.format("megaworm-segment-%d", unit.id))
            if entry ~= nil and entry[1] == worm.id then
                table.insert(thisWorm, unit)
            end
        end
    end

    -- TODO handle missing segments
    if #thisWorm > 0 then
        for i, segment in ipairs(thisWorm) do
            -- TODO sort segments persistently
            worm:addSegment(segment)
        end
        debug('success: claimed')
        return true
    end
    debug('no segments found')
    return false
end

-- Collect fresh segments that have not yet been claimed
function collectUnclaimedSegments(worm)
    -- TODO from raws
    local n = 10

    local units = df.global.world.units.all
    local race = worm.head.race
    local unclaimed = {}

    debug('collectUnclaimedSegments')
    for i,unit in ipairs(units) do
        if unit.race == race and unit.caste == 1 then
            local entry = dfhack.persistent.get(string.format("megaworm-segment-%d", unit.id))
            if entry == nil then
                debug("unclaimed:", i, unit)
                table.insert(unclaimed, unit)
            else
                debug("claimed:", i, unit)
            end
        end
    end

    if #unclaimed > 0 then
        for i = 1,n do
            worm:addSegment(unclaimed[i])
            local entry = dfhack.persistent.save({key=string.format("megaworm-segment-%d", unclaimed[i].id)})
            entry[1] = worm.id
        end
        debug('success: unclaimed')
    else
        dfhack.printerr('megaworm: failed to find unclaimed segments for worm', worm.id)
    end
end

-- Make sure segments aren't disconnected
function collateSegments(worm)
    for i=1,#worm.segments do
        -- best effort
        local prev = worm:getPortion(i-1)
        local cur = worm:getPortion(i)
        if not isReachable(prev.pos, cur.pos) then
            teleport(cur, prev.pos)
        end
    end
end

--- MOTION ---
function stopFightingYouFucks(worm)
    for i = 0,#worm.segments do
        if worm.ids[worm:getPortion(i).opponent.unit_id] ~= nil then
            -- debug('should not fight', worm:getPortion(i).id, worm:getPortion(i).opponent.unit_id)
            -- worm:getPortion(i).opponent.unit_id = -1
            -- worm:getPortion(i).civ_id = 1
        end
    end
end

function moveSegments(worm)
    if not positionEquals(worm.head.pos, worm.last_head_pos) then
        for i = #worm.segments, 2, -1 do
            teleport(worm:getPortion(i), worm:getPortion(i-1).pos)
        end
        teleport(worm:getPortion(1), worm.last_head_pos)
        worm.last_head_pos.x = worm.head.pos.x
        worm.last_head_pos.y = worm.head.pos.y
        worm.last_head_pos.z = worm.head.pos.z
    end
end
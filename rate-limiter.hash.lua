
---
--- @param KEYS[1] event key (source IP address, user id, etc).
--- @param ARGV[1] event count: 1 to increment the counter and test; 0 to only test.
--- @param ARGV[2] JSON array of limits. Each limit is an array of:
---                maxOccurrences
---                limitDuration (in T)
---                limitResolution (in T).
--- @param ARGV[3] current timestamp (in T).
--- @param ARGV[4] event name prefix in Redis.
--- @author Gonzalo Arana <gonzalo.arana@gmail.com>
--- Cleanup can be heavy if limitDuration/limitResolution ratio is large.

local eventKey = KEYS[1];
local eventCount = tonumber(ARGV[1] or '1');

-- TODO validate it's non-negative.

local limits = cjson.decode(ARGV[2])
-- [
--    [ 5, 3600, 60 ], // 5 events per hour, resolution of 1 minute.
--    [ 1, 60, 60 ], // 1 event per minute
-- ]
--
local now = tonumber(ARGV[3])

local eventSetNamePrefix = ARGV[4];

local exceeded = false

for iLimit, limit in pairs(limits) do
    local limitEvents = limit[1]
    local limitDuration = limit[2]
    local limitResolution = limit[3]

    local eventSetName = eventSetNamePrefix .. ':{' .. eventKey .. '}:' .. limitResolution ..  ':' .. limitEvents .. ':' .. limitDuration
    local eventSetEventKey = math.floor(now / limitResolution)
    local eventSetCountKey = 0;

    -- entries older than this time are expired
    local minTime = now - limitDuration;

    local currentEventCount = 0;
    local scanCursor = 0;

    -- cleanup aged entries
    local done = false
    repeat
        local scanResult = redis.call('HSCAN', eventSetName, scanCursor)
        scanCursor = scanResult[1]
        local countsAndKeys = scanResult[2]
        local entryCount = #countsAndKeys / 2;
        if (entryCount > 0) then
            for i=0,entryCount-1 do
                local index = 2 * i;
                local scannedEntryTS = tonumber(countsAndKeys[index + 1]);
                local scannedEntryCount = tonumber(countsAndKeys[index + 2]);
                if
                    (scannedEntryTS ~= 0) and
                    (scannedEntryTS < minTime)
                then
                    redis.call('HDEL', eventSetName, scannedEntryTS)
                    currentEventCount = currentEventCount - scannedEntryCount
                end
            end
            done = scanCursor == '0'
        else
            done = true
        end
        if (scanCursor == '0') then
            done = true
        end
    until done

    if (eventCount > 0) then
        -- if we are actually updating
        currentEventCount = redis.call('HINCRBY', eventSetName, eventSetCountKey, eventCount + currentEventCount)
        redis.call('HINCRBY', eventSetName, eventSetEventKey, eventCount)
    else
        -- if we are checking if the limit has been reached
        -- and no cleanup was done
        if (currentEventCount == 0) then
            currentEventCount = currentEventCount + redis.call('HGET', eventSetName, eventSetCountKey);
        else
            -- no cleanup was done
            currentEventCount = redis.call('HINCRBY', eventSetName, eventSetCountKey, currentEventCount)
        end
    end

    if (currentEventCount > limitEvents) then
        exceeded = true
        -- Would be nice to return how much does it has to wait
        -- This implies doing an ordered scan of the buckets, from oldest to newest.
    end

    redis.call('EXPIRE', eventSetName, limitDuration)
end

return exceeded

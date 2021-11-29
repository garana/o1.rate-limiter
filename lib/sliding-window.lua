
---
--- @param KEYS[1] event key (source IP address, user id, etc).
--- @param ARGV[1] event count:
---                1 or higher to increment the counter and test;
---                0 to only test.
---                less than zero to reset the rate limiter state.
--- @param ARGV[2] eventNamespace: event name prefix in Redis.
--- @param ARGV[3] JSON array of limits. Each limit is an array of:
---                maxOccurrences
---                limitDuration (in T)
---                limitResolution (in T).
--- @param ARGV[4] current timestamp (in T).
--- @param ARGV[5] wantWaitTime: if set to true, return value will be how long
---                the user has to wait for a single event to be within the rate
---                limit.
--- @author Gonzalo Arana <gonzalo.arana@gmail.com>

local eventKey = KEYS[1];
local eventCount = tonumber(ARGV[1] or '1');

local eventNamespace = ARGV[2] or 'rateLimit';

local limits = cjson.decode(ARGV[3])
-- [
--    [ 5, 3600, 60 ], // 5 events per hour, resolution of 1 minute.
--    [ 1, 60, 60 ], // 1 event per minute
-- ]
--
local now = tonumber(ARGV[4])

local wantWaitTime = tonumber(ARGV[5]);

local exceeded = false
local mustWaitFor = 0

for iLimit, limit in pairs(limits) do
    local limitEvents = limit[1]
    local limitDuration = limit[2]
    local limitResolution = limit[3]

    local timeBuckets = math.ceil(limitDuration / limitResolution)
    local keyPrefix = eventNamespace .. ':{' .. eventKey .. '}:' .. limitEvents .. ':' .. limitResolution ..  ':' .. limitDuration
    local listKey = keyPrefix .. ':events';
    local counterKey = keyPrefix .. ':counter';
    local timeKey = math.floor(now / limitResolution)

    if (eventCount < 0) then
        redis.call('DEL', listKey);
        redis.call('DEL', counterKey);
    else

        -- entries older than this time are expired
        local minTime = now - limitDuration;
        local minTimeKey = math.floor(minTime / limitResolution)
        local expiredEventsCounter = 0;

        local done = false;
        repeat

            local olderEntryList = redis.call('LRANGE', listKey, 0, 0)
            if (#olderEntryList == 0) then
                done = true
            else
                local entryTimeKey
                local entryCounter
                entryTimeKey, entryCounter = string.match(olderEntryList[1], "(%d+):(%d+)");
                entryTimeKey = tonumber(entryTimeKey);
                entryCounter = tonumber(entryCounter);
                if (entryTimeKey <= minTimeKey) then
                    redis.call('LPOP', listKey, 1)
                    expiredEventsCounter = expiredEventsCounter + entryCounter;
                else
                    done = true
                end
            end

        until done

        local eventCounterDelta = eventCount - expiredEventsCounter;
        local currentEventCount;

        -- update the right tail node, or add new one.
        if (eventCount > 0) then
            local pushNewEntry = false;
            local newerEntryList = redis.call('LRANGE', listKey, -1, -1);
            if (#newerEntryList == 0) then
                pushNewEntry = true
            else
                local entryTimeKey
                local entryCounter
                entryTimeKey, entryCounter = string.match(newerEntryList[1], "(%d+):(%d+)");
                entryTimeKey = tonumber(entryTimeKey);
                entryCounter = tonumber(entryCounter);
                if (entryTimeKey < timeKey) then
                    pushNewEntry = true;
                    -- Would be great to add clock skew detection.
                else
                    redis.call('LSET', listKey, -1, entryTimeKey .. ':' .. (entryCounter + eventCount));
                end
            end

            if (pushNewEntry) then
                redis.call('RPUSH', listKey, timeKey .. ':' .. eventCount);
            end
        end

        if (eventCounterDelta ~= 0) then
            currentEventCount = redis.call('INCRBY', counterKey, eventCounterDelta)
        else
            currentEventCount = tonumber(redis.call('GET', counterKey) or "0") or 0;
        end

        if (currentEventCount > limitEvents) then
            exceeded = true

            -- Return how much does it has to wait
            -- This implies doing a list scan of the buckets, from oldest to newest.
            if (wantWaitTime) then
                local remainingEvents = limitEvents;

                local bucketsPerLoop = math.min(timeBuckets, 10);

                local startSlot = 0;

                local remainingCheckDone = false

                repeat
                    local endSlot = startSlot + bucketsPerLoop - 1;
                    local entryList = redis.call('LRANGE', listKey, 0, bucketsPerLoop);
                    if (#entryList == 0) then
                        remainingCheckDone = true
                    else
                        for iEntry = 1, #entryList do
                            local entryTimeKey;
                            local entryCounter;
                            entryTimeKey, entryCounter = string.match(entryList[iEntry], "(%d+):(%d+)");
                            entryTimeKey = tonumber(entryTimeKey);
                            entryCounter = tonumber(entryCounter);

                            remainingEvents = remainingEvents - entryCounter;
                            if (remainingEvents <= 0) then
                                mustWaitFor = math.max(mustWaitFor, (timeKey - entryTimeKey) * limitResolution);
                                remainingCheckDone = true
                                break
                            end
                        end

                        startSlot = endSlot + 1;
                    end
                until remainingCheckDone

            end

        end

        redis.call('EXPIRE', listKey, limitDuration)
        redis.call('EXPIRE', counterKey, limitDuration)
    end
end

if wantWaitTime ~= 0 then
    return mustWaitFor
end

return exceeded

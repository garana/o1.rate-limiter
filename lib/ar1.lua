
---
--- AR(1) (aka "exponential moving average") rate limiter.
--- Pros:
---  * Lower memory usage than sliding window
---    (we keep only one entry per rate limiter key).
---  * Faster execution than sliding window
---
--- Cons:
---  * Harder to grasp, and even harder to justify to non-technical staff.
---
--- In plain english:
---  * On each time slot (`limitResolution` in ARGV[3]), we divide the current
---    counter value by `decayFactor` (also in ARGV[3]).
---  * On each new event, we apply the decay, and increment the current counter
---    value.
---
--- @param KEYS[1] event key (source IP address, user id, etc).
--- @param ARGV[1] event count:
---                1 or higher to increment the counter and test;
---                0 to only test.
---                less than zero to reset the rate limiter state.
--- @param ARGV[2] eventNamespace: event name prefix in Redis.
--- @param ARGV[3] JSON array of limits. Each limit is an array of:
---                maxOccurrences
---                decayFactor
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

---
--- 53 is the number of bits in the mantissa of double precision floating point
--- numbers.
---
local minContribution = 2 ^ -53;

---
--- Rationale on expiration time:
--- On each time slot (timeResolution period), the currentCount will be divided
--- by decayFactor.
--- This means, after N time slots, the eventCount will be:
---    eventCount / decayFactor ^ N
--- We discard the event count when it's contribution to the rate limit
--- threshold is negligible, using `minContribution` as this value.
--- That is:
---        eventCount / decayFactor ^ N < minContribution
---       eventCount * decayFactor ^ -N < minContribution
---                    decayFactor ^ -N < minContribution / eventCount
---                                  -N < log(minContribution / eventCount, decayFactor)
---                                   N > - log(minContribution / eventCount, decayFactor)
--- N is in time slots.
--- The actual time to wait for is N * limitResolution.
--- This means that N will grow roughly as:
---   log(minContribution, decayFactor) + log(eventCount, decayFactor)
---
--- To put this in perspective, here are some example values with
--- decayFactor=2 and
--- limitResolution=1:
---
--- eventCount=1      =>  expire=53
--- eventCount=10     =>  expire=56
--- eventCount=100    =>  expire=59
--- eventCount=1000   =>  expire=62
--- eventCount=10000  =>  expire=66
---
---

for iLimit, limit in pairs(limits) do
    local limitEvents = limit[1]
    local decayFactor = limit[2]
    local limitResolution = limit[3]

    local key = eventNamespace .. ':{' .. eventKey .. '}:' .. limitResolution ..  ':' .. limitEvents .. ':' .. decayFactor
    local timeKey = math.floor(now / limitResolution)

    if (eventCount < 0) then
        redis.call('DEL', key);
    else

        local currentEntry = redis.call('GET', key);
        local currentCount = 0;

        if (currentEntry == false) then
            -- no previous entry
            currentCount = eventCount;
        else
            -- previous entry exists
            local entryTimeKey
            local entryCounter
            entryTimeKey, entryCounter = string.match(currentEntry, "(%d+):(%d+)");
            entryTimeKey = tonumber(entryTimeKey);
            entryCounter = tonumber(entryCounter);
            if (timeKey < entryTimeKey) then
                return redis.error_reply("clock skew detected!");
            end

            currentCount = eventCount +
                    entryCounter / math.pow(decayFactor, timeKey - entryTimeKey)
        end

        if (currentCount == 0) then
            redis.call('DEL', key);
        end

        local expiresIn = math.ceil(
                - math.log(minContribution / currentCount, decayFactor)
        )

        redis.call('SET',
                key, timeKey .. ':' .. currentCount,
                'EX',  expiresIn * limitResolution
        )

        if currentCount > limitEvents then
            exceeded = true
        end

        if (wantWaitTime) then
            local slotsToWait = - math.log(limitEvents / currentCount, decayFactor)
            mustWaitFor = math.max(
                    mustWaitFor,
                    slotsToWait * limitResolution
            )
        end
    end
end

if wantWaitTime ~= 0 then
    redis.call('SET', 'debug', 'mustWaitFor')
    redis.call('SET', 'debug', tostring(mustWaitFor))
    return mustWaitFor
end

return exceeded

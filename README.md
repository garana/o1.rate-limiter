# Rate Limiter for Redis in LUA (RedisCluster compatible)

This is a rate limiter:
* written in LUA for Redis,
* compatible with Redis Cluster (sharding),
* implemented as a sliding window,
* providing simple way to reset it's state.

The core of the rate limiter is in `lib/sliding-window.lua` file.

Another rate limiter implementation is also provided in `lib/ar1.lua`:
* use less memory (only one Redis key/value per limiter config),
* use less CPU,
* it is harder to understand, and to explain to non-technical people.
* Is described in `README.ar1.md`

The rest of this file is about the simpler sliding window implementation.

## Usage

The `lib/sliding-window.lua` script require a single key:
1. `eventKey`: it's the key that defines this event. Each key has its own set of
   time buckets.

And these arguments:
1. `eventCount`: Can be any integer value:
    1. can be negative to reset rate limit state for the given key.
    2. can be 0 (zero): to only test if the rate has been exceeded. Aged time
       slots cleanup is performed in this call as well.
    3. can be any positive integer to increment the counter and test if the
       limit has been exceeded.
2. `eventNamespace`: event name prefix in redis.
3. `limits`: JSON array of the limits configured.
    1. `maxOcurrences`,
    2. `limitDuration`, and
    3. `durationResolution`
4. current timestamp
5. `wantWaitTime`: if truthy and called with `eventCount` being non-negative,
   it will return how much time user has to wait for a single event to be within
   the rate limit.

All three time values (`limitDuration`, `durationResolution` and current
timestamp) can be in any unit (seconds, milliseconds), the only condition is
that they are all consistent.

Note that the Typescript `index.ts` (and the generated `index.js`) send
the current timestamp in seconds; so users of that script should pass
`limitDuration`, `durationResolution` in seconds as well.

## The theory

A rate limiter provide means to detect when a given event is happening faster
than it should.

Let's say you want to limit the number of log in attempts per source IP address
to these two limits:
1. once every 5 seconds,
2. 5 times per hour.

If any of these limits is exceeded, the request should get rejected.

In this case, the configuration of the rate limiter would be:
```
[
    {
       // once every 5 seconds:
       maxOcurrences: 1, // up to one time
       limitDuration: 5, // every 5 seconds
       durationResolution: 1 // each time bucket is 1 second "wide"
    },
    {
       // 5 times per hour
       maxOcurrences: 5, // up to 5 times
       limitDuration: 3600, // per hour
       durationResolution: 10*60 // time resolution of 10 minutes 
    }
]
```

1. `maxOcurrences`: maximum number of times,
2. `limitDuration`: time window we keep count of the events,
3. `durationResolution`: the time window is divided in smaller buckets
   this width (read the next section about the sliding window).


### Data structure

Essentially, for each of the limits passed to the LUA script:
* a list used for each time slot in the sliding window,
* a numeric entry: the total number of events in the window.

The name of the both entries is built with:
* a prefix, configurable in `eventNamespace` arg,
* the event key (source IP address in the description above),
* the 3 parameters described above (`maxOcurrences`, `limitDuration` and
  `durationResolution`).

Each node in the list has two values: 
* the number of events that occurred during this time slot,
* the time slot key (time of the event / `durationResolution`).

An example with this setup:
```
    {
       // 3 times every 1 hour, resolution of 20 minutes
       maxOcurrences: 3, // not more than 3 times
       limitDuration: 3600, // every hour
       durationResolution: 20*60 // each time bucket is 20 minutes "wide"
    },
```

We have to keep track of events of the last hour. Since `durationResolution`
is 20 minutes, we have 3 buckets (an hour lasts 3 x 20 minutes): 

```

 ,----------+----------+----------.
 |  node 0  |  node 1  |  node 2  |
 `----------+----------+----------'
      |          |         |
      |          |         `-> current time bucket
      |          '-----------> previous time bucket
      '----------------------> oldest time bucket
```

As time goes by, and another 20 minutes have passed:

```
 ,---------+----------+----------+----------.
 |  node0  |  node 1  |  node 2  |  node 3  |
 `---------+----------+----------+----------'
      |          |          |         |
      |          |          |         `-> current time bucket
      |          |          '-----------> previous time bucket
      |          '----------------------> oldest time bucket 
      '---------------------------------> expires, gets removed
```

At any time, when a new event is recorded, the current time slot counter
is incremented.

As times goes by, a new slot are added to the right, and the left most is
removed.

If no events have occurred in a time slot, no node is used for that time window.

When a slot is removed, the global counter of the entire time window is
adjusted.

## Performance

The number of Redis operations are, for each limit configured:
1. Cleanup:
   1. one LRANGE call,
   2. for each expired time slot:
      1. one LPOP call
2. Counter update (if `eventCount` > 0):
   1. one LRANGE call,
   2. if there is already a node in the list for the current time slot:
      1. one LSET (index -1) call
   3. else
      1. one RPUSH call
3. if the counter requires update: one INCRBY call.
   This happens if:
   1. either of:
      1. eventCount > 0, or
      2. there are expired time slots,
   2. and they are both not equal (if they compensate, no need to update
      the counter).
4. if the counter does not require an update: one GET call.
5. If `wantWaitTime` is truthy (need to determine how long user has to wait):
   1. up to `timeBuckets` / 10 `LRANGE` calls.
   2. `timeBuckets` = `limitDuration` / `durationResolution`
6. Two `EXPIRE` calls.

### Memory Usage

For each `eventKey`, there is:
* one redis key/value with the total number of events.
* one redis list with the sliding window nodes.

See `Data Structure` above for details.

### Test bench

The test scripts:
* tests/test-ar1
* tests/test-sliding-window

They use the `@o1s/redis-testbench` package, which provide means to
create a redis instance and a redis cluster, as well as provide connectivity
to them from Typescript.

* The single redis instance is available:
  * outside docker-compose: as `localhost:6379`
  * inside docker-compose: as `redis:6379`
* The redis-cluster instances are available:
  * outside docker-compose: `localhost:6380` to `localhost:6385`
    (requires nat support for your redis cluster client).
  * inside docker-compose: as `redis-node-0:6379` to `redis-node-5:6379`.

To test the code:
```
# Use NodeJS 12
nvm use 12

# Install dependencies
npm ci

# Compile TypeScript into JavaScript
npm run build

# Run the tester code, against the redis cluster
REDIS_PORTS=6380,6381,6382,6383,6384,6385 REDIS_AUTH="redis-cluster" \
node tests/test-ar1
REDIS_PORTS=6380,6381,6382,6383,6384,6385 REDIS_AUTH="redis-cluster" \
node tests/test-sliding-window

# Run the tester code, against a single redis:
node tests/test-ar1
node tests/test-sliding-window

```

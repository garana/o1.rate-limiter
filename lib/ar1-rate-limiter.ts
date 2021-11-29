import {AbstractRateLimiter} from "./abstract-rate-limiter";
import {CompatibleRedisClient} from "./compatible-redis-client";

export interface RateLimitSpec {
	maxOccurrences: number;
	decayFactor: number;
	durationResolution: number;
}

export class RateLimiter extends AbstractRateLimiter {

	constructor(
		eventNamespace: string,
		limits: RateLimitSpec[],
		redisClient: CompatibleRedisClient,
	) {
		super(
			eventNamespace,
			JSON.stringify(
				limits.map(limit => [
					limit.maxOccurrences,
					limit.decayFactor,
					limit.durationResolution
				])
			),
			redisClient,
			`${__dirname}/ar1.lua`
		);
	}

}

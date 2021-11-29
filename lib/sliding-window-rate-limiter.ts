import {AbstractRateLimiter} from "./abstract-rate-limiter";
import {CompatibleRedisClient} from "./compatible-redis-client";

export interface RateLimitSpec {
	maxOccurrences: number;
	limitDuration: number;
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
					limit.limitDuration,
					limit.durationResolution
				])
			),
			redisClient,
			`${__dirname}/sliding-window.lua`
		);
	}

}

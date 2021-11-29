import { RateLimiter } from "../lib/ar1-rate-limiter";
import {buildOverloadedClient} from "./build-overloaded-client";

(async () => {
	const redisClient = await buildOverloadedClient();

	/**
	 * Note that these values MUST be in seconds.
	 */
	const limits = [
		{
			/**
			 * One event every 5 seconds, with a resolution of 1 second
			 */
			maxOccurrences: 1.2,
			decayFactor: 2,
			durationResolution: 1
		}
	];

	const limiter = new RateLimiter(
		'ipRateLimit',
		limits,
		redisClient
	);

	// await limiter.reset('1.1.1.1');

	for (let i = 0; i < 3; ++i) {
		console.log([
			await limiter.isExceeded('1.1.1.1', 1, false),
			await limiter.isExceeded('1.1.1.2', 1, false),
			await limiter.isExceeded('1.1.1.3', 1, false),
			await limiter.isExceeded('1.1.1.4', 1, false),
			await limiter.isExceeded('1.1.1.5', 1, false),
			await limiter.isExceeded('1.1.1.6', 1, false),
		]);
	}

})().then(
	() => {
		process.exit(0);
	},
	(err) => {
		console.error(err);
		process.exit(1);
	}
);

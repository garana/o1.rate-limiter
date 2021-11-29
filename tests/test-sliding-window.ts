import { RateLimiter } from "../lib/sliding-window-rate-limiter";
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
			maxOccurrences: 1,
			limitDuration: 5,
			durationResolution: 1
		},
		{
			/**
			 * 5 events every hour, with a resolution of 10 minutes.
			 */
			maxOccurrences: 5,
			limitDuration: 3600,
			durationResolution: 1
		},
	];

	const limiter = await new RateLimiter(
		'ipRateLimit',
		limits,
		redisClient
	);

	await limiter.reset('1.1.1.1');

	for (let i = 0; i < 3; ++i) {
		const result = await limiter.isExceeded('1.1.1.1', 1, true);
		console.log(result);
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

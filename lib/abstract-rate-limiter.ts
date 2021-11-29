import { createHash } from "crypto";
import { readFileSync } from "fs";
import { CompatibleRedisClient } from "./compatible-redis-client";


export abstract class AbstractRateLimiter {

	private readonly script: string;
	private readonly scriptSHA: string;

	/**
	 * Note that this will not load the LUA script.
	 * @param eventNamespace
	 * @param serializedLimits
	 * @param scriptFile
	 * @param redisClient
	 */
	protected constructor(
		readonly eventNamespace: string,
		readonly serializedLimits: string,
		readonly redisClient: CompatibleRedisClient,
		scriptFile: string) {

		this.script = readFileSync(
			scriptFile,
			'utf8'
		);

		this.scriptSHA = createHash('SHA1')
			.update(this.script)
			.digest('hex')
			.toLocaleLowerCase();
	}

	/**
	 * Loads the LUA script in redis.
	 */
	async loadScript(): Promise<void> {

		const redisSHA = await this.redisClient.script(
			'LOAD',
			this.script
		);

		if (this.scriptSHA !== redisSHA) {
			throw new Error(
				`Redis returned unexpected SHA digest: ` +
				`${redisSHA} vs ${this.scriptSHA}`
			);
		}

	}

	protected isExceeded_(
		key: string,
		count: number = 0,
		wantWaitTime: boolean = false):
		Promise<number> {
		return this.redisClient.evalsha(
			this.scriptSHA,
			1,
			key, count,
			this.eventNamespace,
			this.serializedLimits,
			Math.floor(Date.now() / 1000),
			wantWaitTime ? 1 : 0
		);
	}

	protected reset_(key: string): Promise<void> {
		return this.redisClient.evalsha(
			this.scriptSHA,
			1,
			key, -1,
			this.eventNamespace,
			this.serializedLimits,
			0, // this is ignored
			0 // this is ignored
		);
	}

	protected async runScript_<T>(callScript: () => Promise<T>): Promise<T> {
		try {
			return await callScript();
		} catch (error) {
			if (
				(error instanceof Error) &&
				error.message?.match(/NOSCRIPT/)
			) {
				console.log('reloading script');
				await this.loadScript();
				return await callScript()
			}

			throw error;
		}
	}

	/**
	 * Increments the event counter by @param count, and verifies if the
	 * rate has been exceeded.
	 *
	 * @param key eventKey. See `README.md` (`Usage` title) for details.
	 * @param count eventCount. See `README.md` (`Usage` title) for details.
	 *              must be a non-negative number.
	 * @param wantWaitTime If set to truthy, returned value is how much the user
	 *                     has to wait until a new event will not exceed the
	 *                     rate limit.
	 * @returns A truthy value means the rate limit is exceeded. See
	 *          @param wantWaitTime above.
	 */
	async isExceeded(key: string, count: number = 0, wantWaitTime: boolean = false): Promise<number> {
		if (count < 0)
			throw new Error('RateLimit.isExceeded: count has to be non-negative');

		return this.runScript_(() => {
			return this.isExceeded_(key, count, wantWaitTime);
		});
	}

	/**
	 * Resets the rate limit for the @param key.
	 * @param key eventKey.
	 */
	async reset(key: string): Promise<void> {
		return this.runScript_(() => {
			return this.reset_(key);
		});
	}

}
import IORedis from "ioredis";
import debug from "debug";
import { buildClient, buildOptionsFromEnv } from "@o1s/redis-testbench";
import {CompatibleRedisClient} from "../lib/compatible-redis-client";

const logDebug = debug('rate-limiter-test');

/**
 * Builds a compatible Redis client.
 * If we are using Redis Cluster, the "SCRIPT LOAD" command is performed
 * in all masters.
 * This `.script()` method call is invoked from `AbstractRateLimiter`,
 * when the script is not loaded.
 * This way, we handle the case when a new master node gets added to the
 * cluster.
 */
export const buildOverloadedClient = async (): Promise<CompatibleRedisClient> => {
	const redisClient = await buildClient({
		...buildOptionsFromEnv(),
		noReplicas: true
	});

	if (redisClient instanceof IORedis.Cluster) {

		logDebug('overloading client');

		return {

			evalsha: (scriptSHA: string, numKeys: number, ...args: (string | number)[]): Promise<any> => {
				return redisClient.evalsha(scriptSHA, numKeys, ...args);
			},

			script: async (command: 'LOAD' | string, scriptContent: string): Promise<string> => {

				logDebug('loading script');

				if (command.toLocaleUpperCase() !== 'LOAD')
					throw new Error('Unexpected CompatibleRedisClient.script usage');

				const result = await Promise.all((redisClient as IORedis.Cluster)
					.nodes('master')
					.map((node) => {
						logDebug(`loading script in ${node.options.host}:${node.options.port}`);
						return node.script('LOAD', scriptContent)
					}));

				return result[0];
			}
		};
	}

	return redisClient;

}
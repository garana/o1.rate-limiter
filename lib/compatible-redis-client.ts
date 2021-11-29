
export interface CompatibleRedisClient {
	/**
	 * We only use 'LOAD' from 'SCRIPT' command ("SCRIPT" "LOAD").
	 * Note that in redis cluster, the script needs to be loaded in all
	 * masters.
	 * If you use IORedis, @see build-overloaded-client.ts.
	 * @param command
	 * @param scriptContent
	 */
	script(command: 'LOAD' | string, scriptContent: string): Promise<string>;

	/**
	 * Send the "EVALSHA" command.
	 * Should throw on errors.
	 * @param scriptSHA
	 * @param numKeys
	 * @param args
	 */
	evalsha(scriptSHA: string, numKeys: number, ...args: (string | number)[]): Promise<any>;
}

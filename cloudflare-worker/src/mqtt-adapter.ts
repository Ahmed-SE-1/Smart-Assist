import { ApiError } from "./errors.ts";
import type { MqttPublishTransport } from "./types.ts";

/** No broker API/auth pair has been verified for this project; fail closed. */
export class UnconfiguredMqttTransport implements MqttPublishTransport {
  async publish(_topic: string, _payload: string, _qos: 0 | 1 | 2, _retain: boolean): Promise<void> {
    throw new ApiError("unavailable", "EMQX HTTP publishing is not configured for this project.");
  }
}

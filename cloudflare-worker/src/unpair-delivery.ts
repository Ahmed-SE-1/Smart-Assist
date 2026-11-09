import { recordUnpairDeliveryAttempt } from "../../functions/src/controller_pairing.ts";
import type { Logger, MqttPublishTransport, PairingStore } from "./types.ts";

export async function deliverUnpairOperation(args: {
  store: PairingStore;
  operation: Record<string, unknown>;
  mqtt: MqttPublishTransport;
  logger: Logger;
  now: Date;
}): Promise<boolean> {
  const operation = args.operation;
  const attempts = Number(operation.deliveryAttempts ?? 0);
  const delayMs = Math.min(5 * 60_000, 15_000 * 2 ** Math.min(attempts, 4));
  const status = await recordUnpairDeliveryAttempt({ store: args.store,
    operationId: String(operation.operationId), nextDeliveryAt: new Date(args.now.getTime() + delayMs), serverTimestamp: args.now });
  if (!status) return false;
  try {
    const houseId = String(operation.houseId ?? "");
    const controllerId = String(operation.controllerId ?? "");
    const phase = status === "prepared" ? "commit" : "prepare";
    const payload = JSON.stringify({ v: 1, type: "unpair", phase, operationId: operation.operationId,
      houseId, controllerId, expiresAt: operation.expiresAt instanceof Date ? operation.expiresAt.toISOString() : operation.expiresAt });
    await args.mqtt.publish(`smartassist/${houseId}/controllers/${controllerId}/control`, payload, 1, false);
    return true;
  } catch {
    args.logger.warn("mqtt_delivery_unavailable", { operationId: operation.operationId, attempt: attempts + 1 });
    return false;
  }
}

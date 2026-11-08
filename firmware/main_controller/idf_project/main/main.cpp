#include "Arduino.h"
#include "esp_log.h"
#include "esp_partition.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <cstring>

extern bool PROTECTED_NVS_AVAILABLE;
void setup();
void loop();

namespace {
constexpr char TAG[] = "smartassist-storage";

bool initializeEncryptedNvs() {
#if !defined(CONFIG_NVS_ENCRYPTION) || !CONFIG_NVS_ENCRYPTION
  ESP_LOGE(TAG, "CONFIG_NVS_ENCRYPTION is disabled; firmware will not start");
  return false;
#else
  const esp_partition_t* nvsPartition = esp_partition_find_first(
      ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_NVS, "nvs");
  const esp_partition_t* keyPartition = esp_partition_find_first(
      ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_NVS_KEYS, "nvs_keys");
  if (nvsPartition == nullptr || keyPartition == nullptr || !keyPartition->encrypted ||
      nvsPartition->size < 0x3000 || keyPartition->size < 0x1000) {
    ESP_LOGE(TAG, "Required nvs/nvs_keys partitions or encryption flags are missing");
    return false;
  }

  nvs_sec_cfg_t securityConfig = {};
  esp_err_t result = nvs_flash_read_security_cfg(keyPartition, &securityConfig);
  if (result == ESP_ERR_NVS_KEYS_NOT_INITIALIZED) {
    // First boot only: generate keys into an empty key partition. No erase or
    // recovery from corrupt/incompatible partitions is attempted here.
    result = nvs_flash_generate_keys(keyPartition, &securityConfig);
  }
  if (result == ESP_OK) {
    result = nvs_flash_secure_init(&securityConfig);
  }
  std::memset(&securityConfig, 0, sizeof(securityConfig));
  if (result != ESP_OK) {
    ESP_LOGE(TAG, "Encrypted NVS initialization failed: %s", esp_err_to_name(result));
    return false;
  }

  nvs_sec_cfg_t verificationConfig = {};
  result = nvs_flash_read_security_cfg(keyPartition, &verificationConfig);
  std::memset(&verificationConfig, 0, sizeof(verificationConfig));
  if (result != ESP_OK) {
    ESP_LOGE(TAG, "NVS key verification failed: %s", esp_err_to_name(result));
    return false;
  }
  ESP_LOGI(TAG, "Encrypted NVS initialized; key partition and secure NVS API verified");
  return true;
#endif
}
}  // namespace

extern "C" void app_main() {
  if (!initializeEncryptedNvs()) {
    ESP_LOGE(TAG, "Pairing and firmware startup halted; flash data was not erased");
    while (true) vTaskDelay(pdMS_TO_TICKS(1000));
  }

  PROTECTED_NVS_AVAILABLE = true;
  initArduino();
  setup();
  while (true) {
    loop();
    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

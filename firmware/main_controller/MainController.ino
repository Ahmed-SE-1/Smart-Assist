#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <esp_random.h>
#include <ArduinoJson.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <time.h>

#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

// ---------- WiFi Details ----------
const char* WIFI_SSID = "OutsiderNotAllowed";
const char* WIFI_PASSWORD = "123456789@1";

// ---------- EMQX Cloud Details ----------
const char* MQTT_HOST = "ab81af18.ala.asia-southeast1.emqxsl.com";
const int MQTT_PORT = 8883;

const char* MQTT_USERNAME = "smartassist_backend";
const char* MQTT_PASSWORD = "Hermoine@smartassist1";

// Public Firebase Web API key copied from DefaultFirebaseOptions.web. This is
// project routing configuration, not an Admin or MQTT credential.
const char* FIREBASE_WEB_API_KEY = "AIzaSyDyViB6jCVE0mxUYpx-qnBCV8xePDhOp8U";
const char* FIREBASE_CLAIM_URL =
  "https://us-central1-smartassist-18d2a.cloudfunctions.net/claimMainController";
const char* FIREBASE_RECOVER_URL =
  "https://us-central1-smartassist-18d2a.cloudfunctions.net/recoverMainControllerCredentials";
const char* FIREBASE_PREPARED_URL =
  "https://us-central1-smartassist-18d2a.cloudfunctions.net/acknowledgeMainControllerUnpairPrepared";
const char* FIREBASE_COMPLETED_URL =
  "https://us-central1-smartassist-18d2a.cloudfunctions.net/acknowledgeMainControllerUnpairCompleted";
const char* FIREBASE_SIGN_IN_URL_PREFIX =
  "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=";
const char* FIREBASE_REFRESH_URL_PREFIX =
  "https://securetoken.googleapis.com/v1/token?key=";

// GTS Root R1, verified against the Google Trust Services repository. Keep
// this trust anchor separate from the existing EMQX CA certificate.
const char* firebase_ca_cert = R"EOF(
-----BEGIN CERTIFICATE-----
MIIFVzCCAz+gAwIBAgINAgPlk28xsBNJiGuiFzANBgkqhkiG9w0BAQwFADBHMQsw
CQYDVQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZpY2VzIExMQzEU
MBIGA1UEAxMLR1RTIFJvb3QgUjEwHhcNMTYwNjIyMDAwMDAwWhcNMzYwNjIyMDAw
MDAwWjBHMQswCQYDVQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZp
Y2VzIExMQzEUMBIGA1UEAxMLR1RTIFJvb3QgUjEwggIiMA0GCSqGSIb3DQEBAQUA
A4ICDwAwggIKAoICAQC2EQKLHuOhd5s73L+UPreVp0A8of2C+X0yBoJx9vaMf/vo
27xqLpeXo4xL+Sv2sfnOhB2x+cWX3u+58qPpvBKJXqeqUqv4IyfLpLGcY9vXmX7w
Cl7raKb0xlpHDU0QM+NOsROjyBhsS+z8CZDfnWQpJSMHobTSPS5g4M/SCYe7zUjw
TcLCeoiKu7rPWRnWr4+wB7CeMfGCwcDfLqZtbBkOtdh+JhpFAz2weaSUKK0Pfybl
qAj+lug8aJRT7oM6iCsVlgmy4HqMLnXWnOunVmSPlk9orj2XwoSPwLxAwAtcvfaH
szVsrBhQf4TgTM2S0yDpM7xSma8ytSmzJSq0SPly4cpk9+aCEI3oncKKiPo4Zor8
Y/kB+Xj9e1x3+naH+uzfsQ55lVe0vSbv1gHR6xYKu44LtcXFilWr06zqkUspzBmk
MiVOKvFlRNACzqrOSbTqn3yDsEB750Orp2yjj32JgfpMpf/VjsPOS+C12LOORc92
wO1AK/1TD7Cn1TsNsYqiA94xrcx36m97PtbfkSIS5r762DL8EGMUUXLeXdYWk70p
aDPvOmbsB4om3xPXV2V4J95eSRQAogB/mqghtqmxlbCluQ0WEdrHbEg8QOB+DVrN
VjzRlwW5y0vtOUucxD/SVRNuJLDWcfr0wbrM7Rv1/oFB2ACYPTrIrnqYNxgFlQID
AQABo0IwQDAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4E
FgQU5K8rJnEaK0gnhS9SZizv8IkTcT4wDQYJKoZIhvcNAQEMBQADggIBAJ+qQibb
C5u+/x6Wki4+omVKapi6Ist9wTrYggoGxval3sBOh2Z5ofmmWJyq+bXmYOfg6LEe
QkEzCzc9zolwFcq1JKjPa7XSQCGYzyI0zzvFIoTgxQ6KfF2I5DUkzps+GlQebtuy
h6f88/qBVRRiClmpIgUxPoLW7ttXNLwzldMXG+gnoot7TiYaelpkttGsN/H9oPM4
7HLwEXWdyzRSjeZ2axfG34arJ45JK3VmgRAhpuo+9K4l/3wV3s6MJT/KYnAK9y8J
ZgfIPxz88NtFMN9iiMG1D53Dn0reWVlHxYciNuaCp+0KueIHoI17eko8cdLiA6Ef
MgfdG+RCzgwARWGAtQsgWSl4vflVy2PFPEz0tv/bal8xa5meLMFrUKTX5hgUvYU/
Z6tGn6D/Qqc6f1zLXbBwHSs09dR2CQzreExZBfMzQsNhFRAbd03OIozUhfJFfbdT
6u9AWpQKXCBfTkBdYiJ23//OYb2MI3jSNwLgjt7RETeJ9r/tSQdirpLsQBqvFAnZ
0E6yove+7u7Y/9waLd64NnHi/Hm3lCXRSHNboTXns5lndcEZOitHTtNCjv0xyBZm
2tIMPNuzjsmhDYAPexZ3FL//2wmUspO8IFgV6dtxQ/PeEMMA3KgqlbbC1j+Qa3bb
bP6MvPJwNQzcmRk13NfIRmPVNnGuV/u3gm3c
-----END CERTIFICATE-----
)EOF";


// ---------- Node MAC Addresses ----------

// Node 1
uint8_t NODE1_MAC[] = {
  0xC8, 0x85, 0x41, 0xC5, 0xE0, 0xD8
};

// Node 2
uint8_t NODE2_MAC[] = {
  0x20, 0x9B, 0xA9, 0x74, 0x3C, 0x38
};


// ---------- CA Certificate ----------

const char* ca_cert = R"EOF(
-----BEGIN CERTIFICATE-----
MIIDjjCCAnagAwIBAgIQAzrx5qcRqaC7KGSxHQn65TANBgkqhkiG9w0BAQsFADBh
MQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3
d3cuZGlnaWNlcnQuY29tMSAwHgYDVQQDExdEaWdpQ2VydCBHbG9iYWwgUm9vdCBH
MjAeFw0xMzA4MDExMjAwMDBaFw0zODAxMTUxMjAwMDBaMGExCzAJBgNVBAYTAlVT
MRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5j
b20xIDAeBgNVBAMTF0RpZ2lDZXJ0IEdsb2JhbCBSb290IEcyMIIBIjANBgkqhkiG
9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuzfNNNx7a8myaJCtSnX/RrohCgiN9RlUyfuI
2/Ou8jqJkTx65qsGGmvPrC3oXgkkRLpimn7Wo6h+4FR1IAWsULecYxpsMNzaHxmx
1x7e/dfgy5SDN67sH0NO3Xss0r0upS/kqbitOtSZpLYl6ZtrAGCSYP9PIUkY92eQ
q2EGnI/yuum06ZIya7XzV+hdG82MHauVBJVJ8zUtluNJbd134/tJS7SsVQepj5Wz
tCO7TG1F8PapspUwtP1MVYwnSlcUfIKdzXOS0xZKBgyMUNGPHgm+F6HmIcr9g+UQ
vIOlCsRnKPZzFBQ9RnbDhxSJITRNrw9FDKZJobq7nMWxM4MphQIDAQABo0IwQDAP
BgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBhjAdBgNVHQ4EFgQUTiJUIBiV
5uNu5g/6+rkS7QYXjzkwDQYJKoZIhvcNAQELBQADggEBAGBnKJRvDkhj6zHd6mcY
1Yl9PMWLSn/pvtsrF9+wX3N3KjITOYFnQoQj8kVnNeyIv/iPsGEMNKSuIEyExtv4
NeF22d+mQrvHRAiGfzZ0JFrabA0UWTW98kndth/Jsw1HKj2ZL7tcu7XUIOGZX1NG
Fdtom/DzMNU+MeKNhJ7jitralj41E6Vf8PlwUHBHQRFXGU7Aj64GxJUTFy8bJZ91
8rGOmaFvE7FBcf6IKshPECBV1/MUReXgRPTqh5Uykw7+U0b6LJ3/iyK5S9kJRaTe
pLiaWN0bfVKfjllDiIGknibVb63dDcY3fe0Dkhvld1927jyNxF1WW6LZZm6zNTfl
MrY=
-----END CERTIFICATE-----
)EOF";


// ---------- MQTT Setup ----------

WiFiClientSecure secureClient;
PubSubClient mqttClient(secureClient);
WiFiClientSecure firebaseSecureClient;
Preferences preferences;

String commandTopic;
String pirEventTopic;
String controllerControlTopic;
String houseId;
String controllerId;
String firebaseRefreshToken;
String firebaseIdToken;  // RAM only; never persisted or printed.
String pendingUnpairHouseId;  // Recovery routing metadata, not an active House assignment.
String unpairOperationId;
String unpairPhase;
String pendingRecoverySecret;  // Device-generated, short-lived; protected NVS only.
String volatilePairingToken;  // RAM only; never persisted.
int credentialGeneration = 0;
uint32_t idTokenExpiresAtMs = 0;
uint32_t nextMqttAttemptMs = 0;
uint32_t nextWifiAttemptMs = 0;
uint32_t nextAckAttemptMs = 0;
uint32_t nextPairingAttemptMs = 0;
bool wifiStarted = false;
bool espNowReady = false;
bool blePairingBusy = false;
bool preferencesReady = false;

static const char* BLE_SERVICE_UUID = "9b0a1000-6f2a-4d71-9c3e-2a4b5c6d7e80";
static const char* BLE_REQUEST_UUID = "9b0a1001-6f2a-4d71-9c3e-2a4b5c6d7e80";
static const char* BLE_RESULT_UUID = "9b0a1002-6f2a-4d71-9c3e-2a4b5c6d7e80";
BLECharacteristic* pairingResultCharacteristic = nullptr;
QueueHandle_t pairingRequestQueue = nullptr;
QueueHandle_t unpairMessageQueue = nullptr;

struct PairingRequestMessage {
  char token[44];
};

struct UnpairMessage {
  char payload[384];
};


// ---------- PIR Event Queue ----------

// Event message received from Node 2
struct PirEventMessage {
  char payload[200];
  uint8_t attempts;
  uint32_t retryAtMs;
};

QueueHandle_t pirEventQueue = nullptr;

// Set true only by app_main after the encrypted NVS API initializes and verifies.
bool PROTECTED_NVS_AVAILABLE = false;

bool isMacControllerId(const String& value) {
  if (value.length() != 17 || !value.startsWith("CTRL_")) return false;
  for (size_t i = 5; i < value.length(); i++) {
    const char c = value[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  return true;
}

String deriveControllerId() {
  uint8_t mac[6] = {};
  WiFi.macAddress(mac);
  char value[18] = {};
  snprintf(value, sizeof(value), "CTRL_%02x%02x%02x%02x%02x%02x",
           mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
  return String(value);
}

bool validOperationId(const String& value) {
  if (value.length() < 32 || value.length() > 64) return false;
  for (size_t i = 0; i < value.length(); i++) {
    const char c = value[i];
    if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
          (c >= '0' && c <= '9') || c == '_' || c == '-')) return false;
  }
  return true;
}

bool validPairingToken(const String& token) {
  if (token.length() != 43) return false;
  for (size_t i = 0; i < token.length(); i++) {
    const char c = token[i];
    if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
          (c >= '0' && c <= '9') || c == '_' || c == '-')) return false;
  }
  return true;
}

String makeRecoverySecret() {
  uint8_t randomBytes[32] = {};
  esp_fill_random(randomBytes, sizeof(randomBytes));
  static const char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  char encoded[44] = {};
  uint32_t accumulator = 0;
  int bits = 0;
  size_t output = 0;
  for (uint8_t byte : randomBytes) {
    accumulator = (accumulator << 8) | byte;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      encoded[output++] = alphabet[(accumulator >> bits) & 0x3f];
    }
  }
  if (bits > 0) encoded[output++] = alphabet[(accumulator << (6 - bits)) & 0x3f];
  memset(randomBytes, 0, sizeof(randomBytes));
  return String(encoded);
}

String urlEncode(const String& input) {
  static const char hex[] = "0123456789ABCDEF";
  String output;
  output.reserve(input.length() * 3);
  for (size_t i = 0; i < input.length(); i++) {
    const uint8_t c = static_cast<uint8_t>(input[i]);
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
      output += static_cast<char>(c);
    } else {
      output += '%';
      output += hex[(c >> 4) & 0x0f];
      output += hex[c & 0x0f];
    }
  }
  return output;
}

bool postHttps(const String& url, const String& body, const String& bearer,
               const char* contentType, String& responseBody, int& httpCode) {
  HTTPClient http;
  firebaseSecureClient.setCACert(firebase_ca_cert);
  firebaseSecureClient.setTimeout(8000);
  if (!http.begin(firebaseSecureClient, url)) return false;
  http.setTimeout(8000);
  http.setConnectTimeout(8000);
  http.addHeader("Content-Type", contentType);
  if (bearer.length() > 0) http.addHeader("Authorization", "Bearer " + bearer);
  httpCode = http.POST(reinterpret_cast<const uint8_t*>(body.c_str()), body.length());
  if (httpCode > 0) responseBody = http.getString();
  http.end();
  return httpCode >= 200 && httpCode < 300;
}

bool callablePost(const char* endpoint, JsonDocument& data, const String& bearer,
                  JsonDocument& response) {
  StaticJsonDocument<2048> request;
  request["data"] = data;
  String requestBody;
  serializeJson(request, requestBody);
  String responseBody;
  int httpCode = 0;
  if (!postHttps(endpoint, requestBody, bearer, "application/json",
                 responseBody, httpCode)) {
    Serial.printf("Firebase callable transport/status failure (%d).\n", httpCode);
    return false;
  }
  const DeserializationError error = deserializeJson(response, responseBody);
  if (error || response["error"].is<JsonObject>()) {
    Serial.println("Firebase callable returned an error or invalid response.");
    return false;
  }
  return response["result"].is<JsonObject>();
}

bool signInWithCustomToken(const String& customToken, const String& expectedUid,
                           String& newRefreshToken, String& newIdToken,
                           int& tokenLifetimeSeconds) {
  StaticJsonDocument<2048> request;
  request["token"] = customToken;
  request["returnSecureToken"] = true;
  String body;
  serializeJson(request, body);
  String responseBody;
  int httpCode = 0;
  const String url = String(FIREBASE_SIGN_IN_URL_PREFIX) + FIREBASE_WEB_API_KEY;
  if (!postHttps(url, body, "", "application/json", responseBody, httpCode)) {
    Serial.printf("Firebase custom-token exchange failed (%d).\n", httpCode);
    return false;
  }
  DynamicJsonDocument response(4096);
  if (deserializeJson(response, responseBody) ||
      !response["localId"].is<const char*>() ||
      String(response["localId"].as<const char*>()) != expectedUid ||
      !response["refreshToken"].is<const char*>() ||
      !response["idToken"].is<const char*>() ||
      !response["expiresIn"].is<const char*>()) {
    Serial.println("Firebase custom-token response was invalid.");
    return false;
  }
  newRefreshToken = response["refreshToken"].as<String>();
  newIdToken = response["idToken"].as<String>();
  tokenLifetimeSeconds = atoi(response["expiresIn"].as<const char*>());
  return newRefreshToken.length() > 0 && newIdToken.length() > 0 &&
         tokenLifetimeSeconds > 0;
}

bool refreshFirebaseIdToken(bool force = false) {
  if (firebaseIdToken.length() > 0 && !force &&
      static_cast<int32_t>(idTokenExpiresAtMs - millis()) > 120000) return true;
  if (firebaseRefreshToken.isEmpty()) return false;
  const String url = String(FIREBASE_REFRESH_URL_PREFIX) + FIREBASE_WEB_API_KEY;
  const String body = "grant_type=refresh_token&refresh_token=" +
                      urlEncode(firebaseRefreshToken);
  String responseBody;
  int httpCode = 0;
  if (!postHttps(url, body, "", "application/x-www-form-urlencoded",
                 responseBody, httpCode)) {
    Serial.printf("Firebase ID-token refresh failed (%d).\n", httpCode);
    return false;
  }
  DynamicJsonDocument response(4096);
  if (deserializeJson(response, responseBody) ||
      !response["id_token"].is<const char*>() ||
      !response["refresh_token"].is<const char*>() ||
      !response["expires_in"].is<const char*>()) {
    Serial.println("Firebase refresh response was invalid.");
    return false;
  }
  const String rotated = response["refresh_token"].as<String>();
  const String newIdToken = response["id_token"].as<String>();
  const int lifetime = atoi(response["expires_in"].as<const char*>());
  if (rotated.isEmpty() || newIdToken.isEmpty() || lifetime <= 0) return false;
  if (!PROTECTED_NVS_AVAILABLE ||
      preferences.putString("fb_refresh", rotated) != rotated.length()) {
    Serial.println("Protected refresh-token persistence unavailable.");
    return false;
  }
  firebaseRefreshToken = rotated;
  firebaseIdToken = newIdToken;
  idTokenExpiresAtMs = millis() + static_cast<uint32_t>(lifetime) * 1000UL;
  return true;
}

bool persistPairing(const String& newHouseId, const String& newControllerId,
                    const String& newRefreshToken, int newGeneration) {
  if (!PROTECTED_NVS_AVAILABLE || !preferencesReady) return false;
  if (!houseId.isEmpty() &&
      (houseId != newHouseId || controllerId != newControllerId)) return false;
  if (!controllerId.isEmpty() && controllerId != newControllerId) return false;
  if (newHouseId.isEmpty() || !isMacControllerId(newControllerId) ||
      newRefreshToken.isEmpty() || newGeneration <= 0) return false;

  // Write an inactive staging record first. House ID is the final active marker.
  if (preferences.putString("stage_house", newHouseId) != newHouseId.length() ||
      preferences.putString("stage_ctrl", newControllerId) != newControllerId.length() ||
      preferences.putString("stage_refresh", newRefreshToken) != newRefreshToken.length() ||
      preferences.putInt("stage_gen", newGeneration) <= 0 ||
      preferences.putBool("stage_ready", true) == false) return false;
  if (preferences.putString("controller_id", newControllerId) != newControllerId.length() ||
      preferences.putString("fb_refresh", newRefreshToken) != newRefreshToken.length() ||
      preferences.putInt("cred_gen", newGeneration) <= 0 ||
      preferences.putString("house_id", newHouseId) != newHouseId.length()) return false;
  preferences.remove("stage_house");
  preferences.remove("stage_ctrl");
  preferences.remove("stage_refresh");
  preferences.remove("stage_gen");
  preferences.remove("stage_ready");
  controllerId = newControllerId;
  firebaseRefreshToken = newRefreshToken;
  credentialGeneration = newGeneration;
  houseId = newHouseId;
  return true;
}

void loadPersistentIdentity() {
  if (!PROTECTED_NVS_AVAILABLE || !preferences.begin("smartassist", false)) {
    Serial.println("Pairing disabled: encrypted NVS is not configured.");
    return;
  }
  preferencesReady = true;
  constexpr const char* STORAGE_PROBE_KEY = "enc_probe";
  constexpr uint8_t STORAGE_PROBE_VALUE = 0xA7;
  if (preferences.putUChar(STORAGE_PROBE_KEY, STORAGE_PROBE_VALUE) != sizeof(uint8_t) ||
      preferences.getUChar(STORAGE_PROBE_KEY, 0) != STORAGE_PROBE_VALUE) {
    preferences.remove(STORAGE_PROBE_KEY);
    preferences.end();
    preferencesReady = false;
    PROTECTED_NVS_AVAILABLE = false;
    Serial.println("Pairing disabled: encrypted NVS read/write probe failed.");
    return;
  }
  preferences.remove(STORAGE_PROBE_KEY);
  // Recover a complete staging record only when no active House assignment exists.
  const String stagedHouse = preferences.getString("stage_house", "");
  if (preferences.getBool("stage_ready", false) &&
      preferences.getString("house_id", "").isEmpty() &&
      !stagedHouse.isEmpty()) {
    const String stagedController = preferences.getString("stage_ctrl", "");
    const String stagedRefresh = preferences.getString("stage_refresh", "");
    const int stagedGeneration = preferences.getInt("stage_gen", 0);
    const String currentController = preferences.getString("controller_id", "");
    if ((currentController.isEmpty() || currentController == stagedController) &&
        isMacControllerId(stagedController) && !stagedRefresh.isEmpty() &&
        stagedGeneration > 0) {
      preferences.putString("controller_id", stagedController);
      preferences.putString("fb_refresh", stagedRefresh);
      preferences.putInt("cred_gen", stagedGeneration);
      preferences.putString("house_id", stagedHouse);
    }
  }
  houseId = preferences.getString("house_id", "");
  controllerId = preferences.getString("controller_id", "");
  firebaseRefreshToken = preferences.getString("fb_refresh", "");
  credentialGeneration = preferences.getInt("cred_gen", 0);
  pendingUnpairHouseId = preferences.getString("unpair_house", "");
  unpairOperationId = preferences.getString("unpair_op", "");
  unpairPhase = preferences.getString("unpair_phase", "");
  pendingRecoverySecret = preferences.getString("pair_recover", "");
  if (!pendingRecoverySecret.isEmpty() && !validPairingToken(pendingRecoverySecret)) {
    preferences.remove("pair_recover");
    pendingRecoverySecret = "";
  }
  if (!controllerId.isEmpty() && !isMacControllerId(controllerId)) {
    Serial.println("Stored controller identity is invalid; pairing is disabled.");
    controllerId = "";
  }
  if (!unpairOperationId.isEmpty() && !validOperationId(unpairOperationId)) {
    Serial.println("Stored unpair recovery record is invalid; refusing recovery.");
    unpairPhase = "invalid";
  }
  if (!unpairPhase.isEmpty() && unpairPhase != "prepared" &&
      unpairPhase != "commit" && unpairPhase != "invalid") {
    Serial.println("Stored unpair phase is invalid; refusing House operations.");
    unpairPhase = "invalid";
  }
  if (unpairPhase == "commit") {
    if (pendingUnpairHouseId.isEmpty() || unpairOperationId.isEmpty()) {
      unpairPhase = "invalid";
    } else {
      // Commit is durable before clearing; recover a reset between those writes.
      preferences.remove("house_id");
      houseId = "";
    }
  }
  if (!houseId.isEmpty() &&
      (!isMacControllerId(controllerId) || firebaseRefreshToken.isEmpty() ||
       credentialGeneration <= 0)) {
    Serial.println("Stored paired identity is incomplete; House operations disabled.");
    unpairPhase = "invalid";
  } else if (!houseId.isEmpty() && !pendingRecoverySecret.isEmpty()) {
    // A complete staged refresh token survived a reset; discard the recovery secret.
    preferences.remove("pair_recover");
    pendingRecoverySecret = "";
  }
  if (controllerId.isEmpty()) controllerId = deriveControllerId();
}

void sendBleFailure(const char* code) {
  if (pairingResultCharacteristic == nullptr) return;
  StaticJsonDocument<160> response;
  response["v"] = 1;
  response["ok"] = false;
  response["error"]["code"] = code;
  String encoded;
  serializeJson(response, encoded);
  pairingResultCharacteristic->setValue(encoded.c_str());
  pairingResultCharacteristic->notify();
}

void sendBlePairingSuccess(const String& assignedHouseId, const String& assignedControllerId) {
  if (pairingResultCharacteristic == nullptr) return;
  StaticJsonDocument<320> response;
  response["v"] = 1;
  response["ok"] = true;
  JsonObject result = response.createNestedObject("result");
  result["houseId"] = assignedHouseId;
  result["controllerId"] = assignedControllerId;
  result["status"] = "paired";
  String encoded;
  serializeJson(response, encoded);
  // Flutter has no notification chunk reassembly; do not send a truncated result.
  if (encoded.length() > 182) {
    Serial.println("BLE result exceeds negotiated MTU contract.");
    sendBleFailure("response-too-large");
    return;
  }
  pairingResultCharacteristic->setValue(encoded.c_str());
  pairingResultCharacteristic->notify();
}

class PairingRequestCallbacks final : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    const std::string value = characteristic->getValue();
    if (value.empty() || value.size() > 128 || pairingRequestQueue == nullptr) {
      sendBleFailure("invalid-argument");
      return;
    }
    StaticJsonDocument<160> request;
    const DeserializationError error = deserializeJson(request, value.data(), value.size());
    if (error || request["v"] != 1 || !request["token"].is<const char*>()) {
      sendBleFailure("invalid-argument");
      return;
    }
    const String token = request["token"].as<String>();
    if (!validPairingToken(token)) {
      sendBleFailure("invalid-argument");
      return;
    }
    PairingRequestMessage message = {};
    memcpy(message.token, token.c_str(), token.length());
    message.token[token.length()] = '\0';
    if (xQueueSend(pairingRequestQueue, &message, 0) != pdTRUE) {
      sendBleFailure("unavailable");
    }
    // The handler persists this capability to protected NVS before HTTP.
  }
};

class PairingServerCallbacks final : public BLEServerCallbacks {
  void onDisconnect(BLEServer*) override {
    BLEDevice::startAdvertising();
  }
};

void startPairingBle() {
  BLEDevice::init("SmartAssist Main");
  BLEDevice::setMTU(185);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new PairingServerCallbacks());
  BLEService* service = server->createService(BLE_SERVICE_UUID);
  BLECharacteristic* request = service->createCharacteristic(
      BLE_REQUEST_UUID, BLECharacteristic::PROPERTY_WRITE);
  request->setCallbacks(new PairingRequestCallbacks());
  pairingResultCharacteristic = service->createCharacteristic(
      BLE_RESULT_UUID,
      BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_INDICATE);
  pairingResultCharacteristic->addDescriptor(new BLE2902());
  service->start();
  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(BLE_SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.println("Main Controller BLE pairing service ready.");
}

bool parseUtcIso8601(const char* value, time_t& result) {
  if (value == nullptr || strlen(value) < 20 || value[19] != 'Z') return false;
  int year, month, day, hour, minute, second;
  if (sscanf(value, "%4d-%2d-%2dT%2d:%2d:%2d", &year, &month, &day,
             &hour, &minute, &second) != 6) return false;
  if (year < 2024 || month < 1 || month > 12 || day < 1 || day > 31 ||
      hour > 23 || minute > 59 || second > 60) return false;
  struct tm parsed = {};
  parsed.tm_year = year - 1900;
  parsed.tm_mon = month - 1;
  parsed.tm_mday = day;
  parsed.tm_hour = hour;
  parsed.tm_min = minute;
  parsed.tm_sec = second;
  result = mktime(&parsed);  // setup() fixes TZ to UTC.
  return result > 0;
}

bool acknowledgeUnpair(bool completed) {
  if (unpairOperationId.isEmpty() || controllerId.isEmpty() ||
      firebaseRefreshToken.isEmpty()) return false;
  if (!refreshFirebaseIdToken()) return false;
  StaticJsonDocument<256> data;
  data["operationId"] = unpairOperationId;
  data["controllerId"] = controllerId;
  DynamicJsonDocument response(2048);
  const bool ok = callablePost(completed ? FIREBASE_COMPLETED_URL : FIREBASE_PREPARED_URL,
                               data, firebaseIdToken, response);
  if (!ok) return false;
  JsonObject result = response["result"].as<JsonObject>();
  const char* expectedStatus = completed ? "completed" : "prepared";
  if (result["status"] != expectedStatus ||
      result["operationId"] != unpairOperationId ||
      result["controllerId"] != controllerId) {
    Serial.println("Unpair acknowledgement response did not match the pending operation.");
    return false;
  }

  if (!completed) {
    unpairPhase = "prepared";
    preferences.putString("unpair_phase", unpairPhase);
    return true;
  }

  // A confirmed response is the only point at which local recovery state and
  // the old device refresh token are removed.
  preferences.remove("unpair_op");
  preferences.remove("unpair_phase");
  preferences.remove("unpair_house");
  preferences.remove("fb_refresh");
  unpairOperationId = "";
  unpairPhase = "";
  pendingUnpairHouseId = "";
  firebaseRefreshToken = "";
  firebaseIdToken = "";
  idTokenExpiresAtMs = 0;
  if (mqttClient.connected()) mqttClient.disconnect();
  Serial.println("Main Controller unpair completed and confirmed.");
  return true;
}

void receiveUnpairControl(const byte* payload, unsigned int length) {
  if (payload == nullptr || length == 0 || length >= 384) return;
  DynamicJsonDocument message(768);
  if (deserializeJson(message, payload, length) || message["v"] != 1 ||
      message["type"] != "unpair" || !message["phase"].is<const char*>() ||
      !message["operationId"].is<const char*>() ||
      !message["houseId"].is<const char*>() ||
      !message["controllerId"].is<const char*>() ||
      !message["expiresAt"].is<const char*>()) {
    Serial.println("Invalid controller control message ignored.");
    return;
  }
  const String phase = message["phase"].as<String>();
  const String opId = message["operationId"].as<String>();
  const String requestedHouse = message["houseId"].as<String>();
  const String requestedController = message["controllerId"].as<String>();
  time_t expiresAt = 0;
  if (!validOperationId(opId) || requestedController != controllerId ||
      requestedHouse.isEmpty() ||
      (requestedHouse != houseId && requestedHouse != pendingUnpairHouseId) ||
      !parseUtcIso8601(message["expiresAt"].as<const char*>(), expiresAt)) {
    Serial.println("Controller control identity/operation validation failed.");
    return;
  }

  if (phase == "prepare") {
    if (unpairPhase.isEmpty()) {
      const time_t now = time(nullptr);
      if (now < 1700000000 || now >= expiresAt || houseId != requestedHouse ||
          !preferencesReady || !PROTECTED_NVS_AVAILABLE) {
        Serial.println("Prepare cannot be safely accepted yet.");
        return;
      }
      // Persist the exact operation and House before acknowledging preparation.
      if (preferences.putString("unpair_house", houseId) != houseId.length() ||
          preferences.putString("unpair_op", opId) != opId.length() ||
          preferences.putString("unpair_phase", "prepared") != 8) {
        Serial.println("Could not persist unpair preparation; no acknowledgement sent.");
        return;
      }
      pendingUnpairHouseId = houseId;
      unpairOperationId = opId;
      unpairPhase = "prepared";
      if (mqttClient.connected() && !commandTopic.isEmpty()) {
        mqttClient.unsubscribe(commandTopic.c_str());
      }
    } else if (opId != unpairOperationId || requestedHouse != pendingUnpairHouseId ||
               (unpairPhase != "prepared" && unpairPhase != "commit")) {
      Serial.println("Conflicting prepare operation ignored.");
      return;
    }
    // Replays are safe: backend prepared acknowledgements are idempotent.
    acknowledgeUnpair(false);
    return;
  }

  if (phase == "commit") {
    if (unpairPhase != "prepared" && unpairPhase != "commit") return;
    if (opId != unpairOperationId || requestedHouse != pendingUnpairHouseId) return;
    if (unpairPhase != "commit") {
      if (preferences.putString("unpair_phase", "commit") != 6) {
        Serial.println("Could not persist unpair commit state; commit deferred.");
        return;
      }
      unpairPhase = "commit";
      // Preserve the House only as pending operation routing metadata.
      preferences.remove("house_id");
      houseId = "";
      if (mqttClient.connected() && !commandTopic.isEmpty()) {
        mqttClient.unsubscribe(commandTopic.c_str());
      }
    }
    // Do not expire a prepared commit: backend prepared operations remain
    // retryable after expiresAt. Keep op/House/refresh token until response.
    nextAckAttemptMs = millis() + 5000;
    acknowledgeUnpair(true);
    return;
  }
  Serial.println("Unknown controller control phase ignored.");
}

void processPairingRequests() {
  if (pairingRequestQueue == nullptr || blePairingBusy ||
      static_cast<int32_t>(millis() - nextPairingAttemptMs) < 0) return;
  PairingRequestMessage request = {};
  String token;
  bool haveNewPairingRequest = false;
  if (!volatilePairingToken.isEmpty()) {
    token = volatilePairingToken;
  } else if (xQueueReceive(pairingRequestQueue, &request, 0) == pdTRUE) {
    token = String(request.token);
    memset(request.token, 0, sizeof(request.token));
    haveNewPairingRequest = true;
  } else if (pendingRecoverySecret.isEmpty()) {
    return;
  }
  blePairingBusy = true;
  nextPairingAttemptMs = millis() + 10000;

  if (!PROTECTED_NVS_AVAILABLE || !preferencesReady) {
    sendBleFailure("failed-precondition");
    Serial.println("Pairing refused because protected NVS is not configured.");
    blePairingBusy = false;
    return;
  }
  if (!houseId.isEmpty() || !unpairPhase.isEmpty()) {
    sendBleFailure("already-exists");
    blePairingBusy = false;
    return;
  }
  if ((!token.isEmpty() && !validPairingToken(token)) || !isMacControllerId(controllerId)) {
    sendBleFailure("invalid-argument");
    blePairingBusy = false;
    return;
  }

  if (haveNewPairingRequest) {
    pendingRecoverySecret = makeRecoverySecret();
    if (!validPairingToken(pendingRecoverySecret) ||
        preferences.putString("pair_recover", pendingRecoverySecret) != pendingRecoverySecret.length()) {
      sendBleFailure("credential-persistence-failed");
      blePairingBusy = false;
      return;
    }
    volatilePairingToken = token;
  }

  StaticJsonDocument<256> data;
  data["controllerId"] = controllerId;
  DynamicJsonDocument claimResponse(8192);
  bool claimOk = false;
  if (!token.isEmpty()) {
    data["token"] = token;
    data["recoverySecret"] = pendingRecoverySecret;
    claimOk = callablePost(FIREBASE_CLAIM_URL, data, "", claimResponse);
  } else {
    data["recoverySecret"] = pendingRecoverySecret;
    claimOk = callablePost(FIREBASE_RECOVER_URL, data, "", claimResponse);
  }
  if (!claimOk) {
    sendBleFailure(token.isEmpty() ? "credential-recovery-pending" : "claim-failed");
    blePairingBusy = false;
    return;
  }
  JsonObject result = claimResponse["result"].as<JsonObject>();
  JsonObject credential = result["deviceCredential"].as<JsonObject>();
  const String assignedHouse = result["houseId"].as<String>();
  const String returnedController = result["controllerId"].as<String>();
  const String status = result["status"].as<String>();
  String customToken = credential["customToken"].as<String>();
  const String authUid = credential["authUid"].as<String>();
  const int generation = credential["credentialGeneration"] | 0;
  const String expectedAuthUid = "smartassist-controller-" + controllerId;
  if (assignedHouse.isEmpty() || assignedHouse.length() > 128 ||
      returnedController != controllerId || status != "paired" ||
      authUid != expectedAuthUid || customToken.isEmpty() || generation <= 0) {
    sendBleFailure("invalid-result");
    blePairingBusy = false;
    return;
  }

  String newRefreshToken;
  String newIdToken;
  int lifetime = 0;
  const bool signedIn = signInWithCustomToken(customToken, authUid,
                                              newRefreshToken, newIdToken, lifetime);
  // Minimize custom-token lifetime in RAM; never store or log it.
  customToken = "";
  claimResponse.clear();
  if (!signedIn) {
    sendBleFailure("credential-exchange-failed");
    blePairingBusy = false;
    return;
  }
  if (!persistPairing(assignedHouse, controllerId, newRefreshToken, generation)) {
    sendBleFailure("credential-persistence-failed");
    Serial.println("Pairing was not reported successful: secure identity persistence failed.");
    blePairingBusy = false;
    return;
  }
  preferences.remove("pair_recover");
  pendingRecoverySecret = "";
  volatilePairingToken = "";
  firebaseIdToken = newIdToken;
  idTokenExpiresAtMs = millis() + static_cast<uint32_t>(lifetime) * 1000UL;
  sendBlePairingSuccess(houseId, controllerId);
  Serial.println("Main Controller pairing completed.");
  if (mqttClient.connected()) mqttClient.disconnect();
  blePairingBusy = false;
}

void retryPendingUnpairAcknowledgement() {
  if (unpairPhase.isEmpty() || unpairPhase == "invalid" ||
      static_cast<int32_t>(millis() - nextAckAttemptMs) < 0) return;
  nextAckAttemptMs = millis() + 5000;
  if (unpairPhase == "prepared") acknowledgeUnpair(false);
  else if (unpairPhase == "commit") acknowledgeUnpair(true);
}

void drainUnpairMessages() {
  if (unpairMessageQueue == nullptr) return;
  UnpairMessage message = {};
  while (xQueueReceive(unpairMessageQueue, &message, 0) == pdTRUE) {
    receiveUnpairControl(reinterpret_cast<const byte*>(message.payload),
                         strnlen(message.payload, sizeof(message.payload)));
    memset(message.payload, 0, sizeof(message.payload));
  }
}


// ---------- Add ESP-NOW Peers ----------

void setupESPNow() {

  if (espNowReady) return;

  if (esp_now_init() != ESP_OK) {
    Serial.println("ESP-NOW initialization FAILED!");
    return;
  }

  esp_now_peer_info_t peerInfo = {};

  peerInfo.channel = 0;
  peerInfo.encrypt = false;

  // Add Node 1
  memcpy(peerInfo.peer_addr, NODE1_MAC, 6);

  if (esp_now_add_peer(&peerInfo) == ESP_OK) {
    Serial.println("NODE 1 added successfully!");
  } else {
    Serial.println("NODE 1 add failed!");
  }

  // Add Node 2
  memcpy(peerInfo.peer_addr, NODE2_MAC, 6);

  if (esp_now_add_peer(&peerInfo) == ESP_OK) {
    Serial.println("NODE 2 added successfully!");
  } else {
    Serial.println("NODE 2 add failed!");
  }

  // Register ESP-NOW receiver
  esp_now_register_recv_cb(OnDataRecv);

  espNowReady = true;
  Serial.println("ESP-NOW READY!");
}


// ---------- ESP-NOW Receive Callback ----------

void OnDataRecv(
  const esp_now_recv_info_t *info,
  const uint8_t *data,
  int len
) {

  // Only accept PIR events from Node 2
  if (memcmp(info->src_addr, NODE2_MAC, 6) != 0) {
    Serial.println("ESP-NOW: Unknown sender ignored!");
    return;
  }

  const char* prefix = "PIR_EVENT:";
  const size_t prefixLength = strlen(prefix);

  // Check message length
  if (len <= prefixLength) {
    return;
  }

  // Identify PIR event message
  if (memcmp(data, prefix, prefixLength) != 0) {
    return;
  }

  Serial.println("\n========== PIR EVENT RECEIVED ==========");

  PirEventMessage eventMessage = {};

  size_t payloadLength = len - prefixLength;

  if (payloadLength >= sizeof(eventMessage.payload)) {
    Serial.println("PIR event payload too large!");
    return;
  }

  // Remove PIR_EVENT: prefix
  memcpy(
    eventMessage.payload,
    data + prefixLength,
    payloadLength
  );

  eventMessage.payload[payloadLength] = '\0';

  Serial.print("Event JSON: ");
  Serial.println(eventMessage.payload);

  // Queue event for MQTT publishing in loop()
  if (pirEventQueue != nullptr) {

    if (xQueueSend(pirEventQueue, &eventMessage, 0) == pdTRUE) {
      Serial.println("PIR event added to queue!");
    } else {
      Serial.println("PIR event queue FULL! Event dropped.");
    }

  } else {

    Serial.println("PIR event queue unavailable!");

  }

  Serial.println("========================================");
}


// ---------- Process PIR Events ----------

void processPirEvents() {
  if (pirEventQueue == nullptr || !mqttClient.connected() || houseId.isEmpty() ||
      !unpairPhase.isEmpty()) return;
  PirEventMessage eventMessage = {};
  if (xQueueReceive(pirEventQueue, &eventMessage, 0) != pdTRUE) return;
  if (static_cast<int32_t>(millis() - eventMessage.retryAtMs) < 0) {
    xQueueSend(pirEventQueue, &eventMessage, 0);
    return;
  }
  if (mqttClient.publish(pirEventTopic.c_str(), eventMessage.payload)) {
    Serial.println("PIR event forwarded to the House event topic.");
    return;
  }
  if (eventMessage.attempts >= 5) {
    Serial.println("PIR event dropped after bounded MQTT retries.");
    return;
  }
  eventMessage.attempts++;
  const uint8_t shift = eventMessage.attempts > 4 ? 4 : eventMessage.attempts;
  const uint32_t backoff = 500UL << shift;
  eventMessage.retryAtMs = millis() + backoff;
  if (xQueueSend(pirEventQueue, &eventMessage, 0) != pdTRUE) {
    Serial.println("PIR retry queue full; event dropped.");
  }
}


// ---------- Forward MQTT Command ----------

void forwardToNode(
  uint8_t* mac,
  byte* payload,
  unsigned int length,
  const char* nodeName
) {

  if (length > 250) {
    Serial.println("ERROR: ESP-NOW packet too large!");
    return;
  }

  esp_err_t result = esp_now_send(
    mac,
    payload,
    length
  );

  if (result == ESP_OK) {

    Serial.print("Command forwarded to ");
    Serial.println(nodeName);

  } else {

    Serial.print("ESP-NOW send failed: ");
    Serial.println(result);

  }
}


// ---------- MQTT Callback ----------

void mqttCallback(
  char* topic,
  byte* payload,
  unsigned int length
) {
  if (topic == nullptr || payload == nullptr) return;
  if (controllerControlTopic.length() > 0 &&
      controllerControlTopic.equals(topic)) {
    if (unpairMessageQueue == nullptr || length == 0 || length >= 384) return;
    UnpairMessage message = {};
    memcpy(message.payload, payload, length);
    message.payload[length] = '\0';
    if (xQueueSend(unpairMessageQueue, &message, 0) != pdTRUE) {
      Serial.println("Controller control queue full; message deferred to backend retry.");
    }
    return;
  }

  // Keep existing room command bytes and routing unchanged. Once unpair
  // preparation is durable, stop applying House-scoped commands.
  if (houseId.isEmpty() || !unpairPhase.isEmpty()) return;

  Serial.println("MQTT room command received.");
  Serial.print("Topic: ");
  Serial.println(topic);

  if (strstr(topic, "/ROOM1_NODE/cmd") != nullptr) {
    forwardToNode(
      NODE1_MAC,
      payload,
      length,
      "NODE 1"
    );

  }

  else if (strstr(topic, "/ROOM2_NODE/cmd") != nullptr) {

    forwardToNode(
      NODE2_MAC,
      payload,
      length,
      "NODE 2"
    );

  }

  else Serial.println("Unknown room command topic ignored.");
}


// ---------- WiFi Connection ----------

void connectWiFi() {
  static bool configured = false;
  static bool previouslyConnected = false;
  if (!configured) {
    WiFi.mode(WIFI_STA);
    WiFi.setSleep(false);
    WiFi.setAutoReconnect(true);
    configured = true;
  }
  if (WiFi.status() == WL_CONNECTED) {
    if (!previouslyConnected) {
      Serial.println("WiFi connected.");
      Serial.println(WiFi.localIP());
      Serial.printf("WiFi channel: %u\n", WiFi.channel());
      previouslyConnected = true;
      configTime(0, 0, "pool.ntp.org", "time.google.com");
      // ESP-NOW peers use channel 0, i.e. the station's current AP channel.
    }
    return;
  }
  previouslyConnected = false;
  if (!wifiStarted || static_cast<int32_t>(millis() - nextWifiAttemptMs) >= 0) {
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
    wifiStarted = true;
    nextWifiAttemptMs = millis() + 10000;
    Serial.println("WiFi connection attempt started.");
  }
}


// ---------- MQTT Connection ----------

void connectMQTT() {
  if (WiFi.status() != WL_CONNECTED || mqttClient.connected() ||
      static_cast<int32_t>(millis() - nextMqttAttemptMs) < 0) return;
  nextMqttAttemptMs = millis() + 5000;
  String clientId = "SmartAssist-Main-";
  clientId += WiFi.macAddress();
  if (!mqttClient.connect(clientId.c_str(), MQTT_USERNAME, MQTT_PASSWORD)) {
    Serial.printf("MQTT connection attempt failed (%d).\n", mqttClient.state());
    return;
  }
  Serial.println("MQTT connected over verified TLS.");

  const String activeHouse = houseId;
  const String topicHouse = !activeHouse.isEmpty() ? activeHouse : pendingUnpairHouseId;
  commandTopic = activeHouse.isEmpty()
      ? ""
      : "smartassist/" + activeHouse + "/+/cmd";
  pirEventTopic = activeHouse.isEmpty()
      ? ""
      : "smartassist/" + activeHouse + "/ROOM2_NODE/events";
  controllerControlTopic = topicHouse.isEmpty() || controllerId.isEmpty()
      ? ""
      : "smartassist/" + topicHouse + "/controllers/" + controllerId + "/control";

  if (!commandTopic.isEmpty() && unpairPhase.isEmpty()) {
    if (mqttClient.subscribe(commandTopic.c_str())) {
      Serial.println("Existing room command subscription restored.");
    }
  }
  if (!controllerControlTopic.isEmpty()) {
    if (mqttClient.subscribe(controllerControlTopic.c_str())) {
      Serial.println("Controller control subscription restored.");
    }
  }
  if (!activeHouse.isEmpty() && unpairPhase.isEmpty()) {
    mqttClient.publish(("smartassist/" + activeHouse + "/MAIN_01/status").c_str(), "ONLINE");
    Serial.println("PIR event topic configured for ROOM2_NODE.");
  }
}


// ---------- Setup ----------

void setup() {

  Serial.begin(115200);
  setenv("TZ", "UTC0", 1);
  tzset();
  pirEventQueue = xQueueCreate(10, sizeof(PirEventMessage));
  pairingRequestQueue = xQueueCreate(2, sizeof(PairingRequestMessage));
  unpairMessageQueue = xQueueCreate(4, sizeof(UnpairMessage));
  if (pirEventQueue == nullptr || pairingRequestQueue == nullptr ||
      unpairMessageQueue == nullptr) {
    Serial.println("Required event queue creation failed; pairing/control disabled.");
  }

  connectWiFi();
  loadPersistentIdentity();
  startPairingBle();

  // Preserve the existing EMQX CA validation; Firebase uses its own GTS root.
  secureClient.setCACert(ca_cert);
  secureClient.setTimeout(8000);
  firebaseSecureClient.setCACert(firebase_ca_cert);

  mqttClient.setServer(MQTT_HOST, MQTT_PORT);
  mqttClient.setCallback(mqttCallback);
  mqttClient.setBufferSize(512);
  mqttClient.setSocketTimeout(5);
  nextAckAttemptMs = millis() + 5000;
  connectWiFi();
  connectMQTT();
}


// ---------- Main Loop ----------

void loop() {
  connectWiFi();
  if (WiFi.status() == WL_CONNECTED) {
    if (!espNowReady) setupESPNow();
    connectMQTT();
  }
  mqttClient.loop();
  drainUnpairMessages();
  processPairingRequests();
  retryPendingUnpairAcknowledgement();
  processPirEvents();
}

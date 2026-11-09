# SmartAssist storage modes

Storage mode is a firmware build choice. The default is production, which fails
closed unless ESP-IDF's encrypted NVS path is available. Neither mode enables
Flash Encryption, Secure Boot, or writes eFuses.

## Development Mode

From an ESP-IDF 5.1.4 PowerShell environment:

```powershell
cd firmware/main_controller/idf_project
idf.py menuconfig
```

Open **SmartAssist security**, enable `SMARTASSIST_DEVELOPMENT_MODE`, and save.
`SMARTASSIST_REQUIRE_ENCRYPTED_STORAGE` is disabled automatically because it
depends on Development Mode being disabled. Then configure and build:

```powershell
idf.py reconfigure
idf.py build
```

Development uses `nvs_flash_init()` and halts on any initialization error. It
stores only controller/House identity and credential generation metadata.
Firebase tokens, pairing tokens, and recovery secrets stay in RAM. After a
reboot, authenticate or pair again as required. The two-phase unpair recovery
operation is refused with `failed-precondition` because its recovery state
cannot survive a reset securely in this mode.

## Production Mode

Open `idf.py menuconfig` → **SmartAssist security**, disable
`SMARTASSIST_DEVELOPMENT_MODE`, and enable `SMARTASSIST_REQUIRE_ENCRYPTED_STORAGE`.
Save, then:

```powershell
idf.py reconfigure
idf.py build
```

Production requires successful encrypted NVS setup and persists credentials
only through that protected path. On a Classic ESP32 this requires a separately
provisioned device with hardware Flash Encryption configured to protect the NVS
key partition. This project does not provision it. Without the required
configuration, production firmware stops before Arduino, BLE, Wi-Fi, ESP-NOW,
or MQTT startup. Do not use this production configuration on an unprovisioned
device expecting plaintext fallback.

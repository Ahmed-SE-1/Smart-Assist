idf_component_register(
  SRCS "main.cpp" "firmware.cpp"
  INCLUDE_DIRS "."
  REQUIRES arduino-esp32 nvs_flash spi_flash freertos
)

set(ARDUINOJSON_INCLUDE "${PROJECT_DIR}/managed_components/bblanchon__arduinojson/src")
set(PUBSUBCLIENT_DIR "${PUBSUBCLIENT_SOURCE_DIR}/src")
if(NOT EXISTS "${ARDUINOJSON_INCLUDE}/ArduinoJson.h")
  message(FATAL_ERROR "Pinned ArduinoJson component source is missing")
endif()
if(NOT EXISTS "${PUBSUBCLIENT_DIR}/PubSubClient.cpp")
  message(FATAL_ERROR "Pinned PubSubClient v2.8 source is missing; rerun CMake configure with network access")
endif()
target_sources(${COMPONENT_LIB} PRIVATE "${PUBSUBCLIENT_DIR}/PubSubClient.cpp")
target_include_directories(${COMPONENT_LIB} PRIVATE "${ARDUINOJSON_INCLUDE}" "${PUBSUBCLIENT_DIR}")

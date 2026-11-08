cmake_minimum_required(VERSION 3.16)
include(FetchContent)
FetchContent_Declare(
  pubsubclient
  GIT_REPOSITORY https://github.com/knolleary/pubsubclient.git
  GIT_TAG v2.8
  GIT_SHALLOW TRUE
)
FetchContent_GetProperties(pubsubclient)
if(NOT pubsubclient_POPULATED)
  FetchContent_Populate(pubsubclient)
endif()
set(PUBSUBCLIENT_SOURCE_DIR "${pubsubclient_SOURCE_DIR}" CACHE INTERNAL "Pinned PubSubClient source")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(smartassist_main_controller)

# Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
# file Copyright.txt or https://cmake.org/licensing for details.

cmake_minimum_required(VERSION 3.5)

file(MAKE_DIRECTORY
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/_deps/pubsubclient-src"
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/_deps/pubsubclient-build"
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/_deps/pubsubclient-subbuild/pubsubclient-populate-prefix"
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/_deps/pubsubclient-subbuild/pubsubclient-populate-prefix/tmp"
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/_deps/pubsubclient-subbuild/pubsubclient-populate-prefix/src/pubsubclient-populate-stamp"
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/_deps/pubsubclient-subbuild/pubsubclient-populate-prefix/src"
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/_deps/pubsubclient-subbuild/pubsubclient-populate-prefix/src/pubsubclient-populate-stamp"
)

set(configSubDirs )
foreach(subDir IN LISTS configSubDirs)
    file(MAKE_DIRECTORY "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/_deps/pubsubclient-subbuild/pubsubclient-populate-prefix/src/pubsubclient-populate-stamp/${subDir}")
endforeach()
if(cfgdir)
  file(MAKE_DIRECTORY "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/_deps/pubsubclient-subbuild/pubsubclient-populate-prefix/src/pubsubclient-populate-stamp${cfgdir}") # cfgdir has leading slash
endif()

# Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
# file Copyright.txt or https://cmake.org/licensing for details.

cmake_minimum_required(VERSION 3.5)

file(MAKE_DIRECTORY
  "C:/Users/LAPTOPS LOUNGE/esp/esp-idf-v5.1.4/components/bootloader/subproject"
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/bootloader"
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/bootloader-prefix"
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/bootloader-prefix/tmp"
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/bootloader-prefix/src/bootloader-stamp"
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/bootloader-prefix/src"
  "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/bootloader-prefix/src/bootloader-stamp"
)

set(configSubDirs )
foreach(subDir IN LISTS configSubDirs)
    file(MAKE_DIRECTORY "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/bootloader-prefix/src/bootloader-stamp/${subDir}")
endforeach()
if(cfgdir)
  file(MAKE_DIRECTORY "D:/Ahmed/SmartAssist-FYP/SmartAssist App/Smart-Assist/firmware/main_controller/idf_project/build/bootloader-prefix/src/bootloader-stamp${cfgdir}") # cfgdir has leading slash
endif()

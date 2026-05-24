# Install script for directory: C:/seedesktop/see-desk/.vcpkg-buildtrees/aom/src/0dfd393293-89a1dfb899.clean

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "C:/seedesktop/see-desk/$inst")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "Release")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Install shared libraries without execute permission?
if(NOT DEFINED CMAKE_INSTALL_SO_NO_EXE)
  set(CMAKE_INSTALL_SO_NO_EXE "0")
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "TRUE")
endif()

# Set path to fallback-tool for dependency-resolution.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "C:/Users/eli/AppData/Local/Android/Sdk/ndk/26.3.11579264/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-objdump.exe")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/AOM" TYPE FILE FILES
    "C:/seedesktop/see-desk/.manual-aom-build/generated/AOMConfig.cmake"
    "C:/seedesktop/see-desk/.manual-aom-build/generated/AOMConfigVersion.cmake"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/AOM/AOMTargets.cmake")
    file(DIFFERENT _cmake_export_file_changed FILES
         "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/AOM/AOMTargets.cmake"
         "C:/seedesktop/see-desk/.manual-aom-build/CMakeFiles/Export/1d4b5ee603978b91751e4a9c440422b3/AOMTargets.cmake")
    if(_cmake_export_file_changed)
      file(GLOB _cmake_old_config_files "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/AOM/AOMTargets-*.cmake")
      if(_cmake_old_config_files)
        string(REPLACE ";" ", " _cmake_old_config_files_text "${_cmake_old_config_files}")
        message(STATUS "Old export file \"$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/AOM/AOMTargets.cmake\" will be replaced.  Removing files [${_cmake_old_config_files_text}].")
        unset(_cmake_old_config_files_text)
        file(REMOVE ${_cmake_old_config_files})
      endif()
      unset(_cmake_old_config_files)
    endif()
    unset(_cmake_export_file_changed)
  endif()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/AOM" TYPE FILE FILES "C:/seedesktop/see-desk/.manual-aom-build/CMakeFiles/Export/1d4b5ee603978b91751e4a9c440422b3/AOMTargets.cmake")
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Rr][Ee][Ll][Ee][Aa][Ss][Ee])$")
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/AOM" TYPE FILE FILES "C:/seedesktop/see-desk/.manual-aom-build/CMakeFiles/Export/1d4b5ee603978b91751e4a9c440422b3/AOMTargets-release.cmake")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include/aom" TYPE FILE FILES
    "C:/seedesktop/see-desk/.vcpkg-buildtrees/aom/src/0dfd393293-89a1dfb899.clean/aom/aom.h"
    "C:/seedesktop/see-desk/.vcpkg-buildtrees/aom/src/0dfd393293-89a1dfb899.clean/aom/aom_codec.h"
    "C:/seedesktop/see-desk/.vcpkg-buildtrees/aom/src/0dfd393293-89a1dfb899.clean/aom/aom_frame_buffer.h"
    "C:/seedesktop/see-desk/.vcpkg-buildtrees/aom/src/0dfd393293-89a1dfb899.clean/aom/aom_image.h"
    "C:/seedesktop/see-desk/.vcpkg-buildtrees/aom/src/0dfd393293-89a1dfb899.clean/aom/aom_integer.h"
    "C:/seedesktop/see-desk/.vcpkg-buildtrees/aom/src/0dfd393293-89a1dfb899.clean/aom/aom_decoder.h"
    "C:/seedesktop/see-desk/.vcpkg-buildtrees/aom/src/0dfd393293-89a1dfb899.clean/aom/aomdx.h"
    "C:/seedesktop/see-desk/.vcpkg-buildtrees/aom/src/0dfd393293-89a1dfb899.clean/aom/aomcx.h"
    "C:/seedesktop/see-desk/.vcpkg-buildtrees/aom/src/0dfd393293-89a1dfb899.clean/aom/aom_encoder.h"
    "C:/seedesktop/see-desk/.vcpkg-buildtrees/aom/src/0dfd393293-89a1dfb899.clean/aom/aom_external_partition.h"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/pkgconfig" TYPE FILE FILES "C:/seedesktop/see-desk/.manual-aom-build/aom.pc")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE STATIC_LIBRARY FILES "C:/seedesktop/see-desk/.manual-aom-build/libaom.a")
endif()

string(REPLACE ";" "\n" CMAKE_INSTALL_MANIFEST_CONTENT
       "${CMAKE_INSTALL_MANIFEST_FILES}")
if(CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "C:/seedesktop/see-desk/.manual-aom-build/install_local_manifest.txt"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()
if(CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_COMPONENT MATCHES "^[a-zA-Z0-9_.+-]+$")
    set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INSTALL_COMPONENT}.txt")
  else()
    string(MD5 CMAKE_INST_COMP_HASH "${CMAKE_INSTALL_COMPONENT}")
    set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INST_COMP_HASH}.txt")
    unset(CMAKE_INST_COMP_HASH)
  endif()
else()
  set(CMAKE_INSTALL_MANIFEST "install_manifest.txt")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "C:/seedesktop/see-desk/.manual-aom-build/${CMAKE_INSTALL_MANIFEST}"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()

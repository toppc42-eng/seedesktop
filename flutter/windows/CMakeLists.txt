# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(SeeDesktop LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "SeeDesktop")

# Explicitly opt into modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")
# Replace /MD flags to /MT to use static vcruntine
set(CompilerFlags
        CMAKE_CXX_FLAGS
        CMAKE_CXX_FLAGS_DEBUG
        CMAKE_CXX_FLAGS_RELEASE
        CMAKE_C_FLAGS
        CMAKE_C_FLAGS_DEBUG
        CMAKE_C_FLAGS_RELEASE
        )
foreach(CompilerFlag ${CompilerFlags})
  string(REPLACE "/MD" "/MT" ${CompilerFlag} "${${CompilerFlag}}")
endforeach()

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  # Disable VC140_1
  target_compile_options(${TARGET} PRIVATE /d2FH4-)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# flutter_rust_bridge
set(RUSTDESK_LIB_DEBUG "${CMAKE_CURRENT_SOURCE_DIR}/../../target/debug/librustdesk.dll")
set(RUSTDESK_LIB_RELEASE "${CMAKE_CURRENT_SOURCE_DIR}/../../target/release/librustdesk.dll")
install(CODE "
  if(\"\${CMAKE_INSTALL_CONFIG_NAME}\" STREQUAL \"Debug\")
    set(_src \"${RUSTDESK_LIB_DEBUG}\")
  else()
    set(_src \"${RUSTDESK_LIB_RELEASE}\")
  endif()
  set(_dst \"${INSTALL_BUNDLE_LIB_DIR}/librustdesk.dll\")
  set(_copied FALSE)
  foreach(_attempt RANGE 1 3)
    execute_process(
      COMMAND \"${CMAKE_COMMAND}\" -E copy_if_different \"\${_src}\" \"\${_dst}\"
      RESULT_VARIABLE _copy_result
      ERROR_VARIABLE _copy_error
    )
    if(_copy_result EQUAL 0)
      set(_copied TRUE)
      message(STATUS \"Installed librustdesk.dll (attempt \${_attempt}/3)\")
      break()
    endif()
    if(_attempt LESS 3)
      message(WARNING
        \"Failed to install librustdesk.dll (attempt \${_attempt}/3): \${_copy_error}. Retrying in 1 second...\")
      execute_process(COMMAND \"${CMAKE_COMMAND}\" -E sleep 1)
    endif()
  endforeach()
  if(NOT _copied)
    message(FATAL_ERROR
      \"Failed to install librustdesk.dll after 3 attempts from '\${_src}' to '\${_dst}'.\")
  endif()
" COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# Remote printer driver files (Windows).
# The runtime installer resolves the INF relative to the executable path:
#   drivers/RustDeskPrinterDriver/RustDeskPrinterDriver.inf
set(RD_PRINTER_DRIVER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../drivers/RustDeskPrinterDriver")
if(EXISTS "${RD_PRINTER_DRIVER_DIR}/RustDeskPrinterDriver.inf")
  file(GLOB RD_PRINTER_DRIVER_ASSETS
    "${RD_PRINTER_DRIVER_DIR}/*.inf"
    "${RD_PRINTER_DRIVER_DIR}/*.cat"
    "${RD_PRINTER_DRIVER_DIR}/*.dll"
    "${RD_PRINTER_DRIVER_DIR}/*.gpd"
    "${RD_PRINTER_DRIVER_DIR}/*.xml"
    "${RD_PRINTER_DRIVER_DIR}/*.ini")
  if(RD_PRINTER_DRIVER_ASSETS)
    install(FILES ${RD_PRINTER_DRIVER_ASSETS}
      DESTINATION "${CMAKE_INSTALL_PREFIX}/drivers/RustDeskPrinterDriver"
      COMPONENT Runtime)
  else()
    message(WARNING "No RustDesk printer driver assets matched expected extensions.")
  endif()
endif()

# Printer service adapter DLL.
set(RD_PRINTER_ADAPTER_DLL "${CMAKE_CURRENT_SOURCE_DIR}/../../printer_driver_adapter.dll")
# Cloud backup scripts (same GCS credentials pattern as publisher; ship next to exe).
set(SEEDESKTOP_BACKUP_SCRIPTS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/backup_scripts")
if(EXISTS "${SEEDESKTOP_BACKUP_SCRIPTS_DIR}/backup.bat")
  install(FILES
    "${SEEDESKTOP_BACKUP_SCRIPTS_DIR}/backup.bat"
    "${SEEDESKTOP_BACKUP_SCRIPTS_DIR}/backup_package.ps1"
    "${SEEDESKTOP_BACKUP_SCRIPTS_DIR}/restore.bat"
    "${SEEDESKTOP_BACKUP_SCRIPTS_DIR}/list_backups.bat"
    DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
endif()

# GCS backup helper (Rust binary; no PowerShell 7 / no Python on end-user PCs).
set(SEEDESKTOP_BACKUP_HELPER_DEBUG "${CMAKE_CURRENT_SOURCE_DIR}/../../target/debug/seedesktop_backup_helper.exe")
set(SEEDESKTOP_BACKUP_HELPER_RELEASE "${CMAKE_CURRENT_SOURCE_DIR}/../../target/release/seedesktop_backup_helper.exe")
install(CODE "
  if(\"\${CMAKE_INSTALL_CONFIG_NAME}\" STREQUAL \"Debug\")
    set(_hsrc \"${SEEDESKTOP_BACKUP_HELPER_DEBUG}\")
  else()
    set(_hsrc \"${SEEDESKTOP_BACKUP_HELPER_RELEASE}\")
  endif()
  set(_hdst \"${INSTALL_BUNDLE_LIB_DIR}/seedesktop_backup_helper.exe\")
  set(_hcopied FALSE)
  foreach(_attempt RANGE 1 3)
    execute_process(
      COMMAND \"${CMAKE_COMMAND}\" -E copy_if_different \"\${_hsrc}\" \"\${_hdst}\"
      RESULT_VARIABLE _hcopy_result
      ERROR_VARIABLE _hcopy_error
    )
    if(_hcopy_result EQUAL 0)
      set(_hcopied TRUE)
      message(STATUS \"Installed seedesktop_backup_helper.exe (attempt \${_attempt}/3)\")
      break()
    endif()
    if(_attempt LESS 3)
      message(WARNING
        \"Failed to install seedesktop_backup_helper.exe (attempt \${_attempt}/3): \${_hcopy_error}. Retrying in 1 second...\")
      execute_process(COMMAND \"${CMAKE_COMMAND}\" -E sleep 1)
    endif()
  endforeach()
  if(NOT _hcopied)
    message(FATAL_ERROR
      \"Failed to install seedesktop_backup_helper.exe after 3 attempts from '\${_hsrc}' to '\${_hdst}'. Build it with: cargo build -p seedesktop_backup_helper --release\")
  endif()
" COMPONENT Runtime)

if(EXISTS "${RD_PRINTER_ADAPTER_DLL}")
  install(CODE "
    set(_src \"${RD_PRINTER_ADAPTER_DLL}\")
    set(_dst \"${INSTALL_BUNDLE_LIB_DIR}/printer_driver_adapter.dll\")
    set(_copied FALSE)
    foreach(_attempt RANGE 1 3)
      execute_process(
        COMMAND \"${CMAKE_COMMAND}\" -E copy_if_different \"\${_src}\" \"\${_dst}\"
        RESULT_VARIABLE _copy_result
        ERROR_VARIABLE _copy_error
      )
      if(_copy_result EQUAL 0)
        set(_copied TRUE)
        message(STATUS \"Installed printer_driver_adapter.dll (attempt \${_attempt}/3)\")
        break()
      endif()
      if(_attempt LESS 3)
        message(WARNING
          \"Failed to install printer_driver_adapter.dll (attempt \${_attempt}/3): \${_copy_error}. Retrying in 1 second...\")
        execute_process(COMMAND \"${CMAKE_COMMAND}\" -E sleep 1)
      endif()
    endforeach()
    if(NOT _copied)
      message(FATAL_ERROR
        \"Failed to install printer_driver_adapter.dll after 3 attempts from '\${_src}' to '\${_dst}'.\")
    endif()
  " COMPONENT Runtime)
endif()

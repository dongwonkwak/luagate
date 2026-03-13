cmake_minimum_required(VERSION 3.16)
project(luagate_csrc C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Export compile_commands.json for clang-tidy
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Guard each subdir — only add when a real CMakeLists.txt exists
foreach(subdir protocol_parser cidr_matcher)
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${subdir}/CMakeLists.txt")
    add_subdirectory(${subdir})
  else()
    message(STATUS "Skipping ${subdir} — no CMakeLists.txt yet")
  endif()
endforeach()

enable_testing()
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/CMakeLists.txt")
  add_subdirectory(tests)
else()
  message(STATUS "Skipping tests — no CMakeLists.txt yet")
endif()

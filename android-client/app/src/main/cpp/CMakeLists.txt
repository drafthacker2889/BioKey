cmake_minimum_required(VERSION 3.22.1)

project("biokey-native")

add_library(
        biokey-native
        SHARED
        # List C/C++ source files here with relative paths to this CMakeLists.txt.
        # Once integration is complete, you might link against existing native-engine sources
        # or include them here directly. For now, we create a placeholder.
        native-lib.cpp)

find_library(
        log-lib
        log)

target_link_libraries(
        biokey-native
        ${log-lib})

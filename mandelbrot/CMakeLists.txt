#######################################################################################
#
# https://cliutils.gitlab.io/modern-cmake/chapters/packages/CUDA.html
#
#######################################################################################

cmake_minimum_required (VERSION 3.8 FATAL_ERROR)

project (mandelbrot_test LANGUAGES CXX CUDA)

set_property(GLOBAL PROPERTY USE_FOLDERS ON) 

set(CMAKE_CONFIGURATION_TYPES "Debug;Release;RelWithDebInfo" CACHE STRING "Configuration types" FORCE)

set(CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/CMake")

set(EXE_NAME "mandelbrot")

file( GLOB SRC_FILES ${CMAKE_SOURCE_DIR}/src/*.h ${CMAKE_SOURCE_DIR}/src/*.cpp )
file( GLOB CUDA_SRC_FILES ${CMAKE_SOURCE_DIR}/src/*.cu )

include_directories( ${CMAKE_CURRENT_SOURCE_DIR} ${CMAKE_SOURCE_DIR}/src )


#######################################################################################

foreach(f ${SRC_FILES})
    # Get the path of the file relative to ${DIRECTORY},
    # then alter it (not compulsory)
    file(RELATIVE_PATH SRCGR ${CMAKE_SOURCE_DIR} ${f})
    set(SRCGR "Sources/${SRCGR}")

    # Extract the folder, ie remove the filename part
    string(REGEX REPLACE "(.*)(/[^/]*)$" "\\1" SRCGR ${SRCGR})

    # Source_group expects \\ (double antislash), not / (slash)
    string(REPLACE / \\ SRCGR ${SRCGR})
    source_group("${SRCGR}" FILES ${f})
endforeach()

if(WINDOWS)
  set(GUI_TYPE WIN32)
elseif(MACOSX)
  set(GUI_TYPE MACOSX_BUNDLE)
endif()

if(MSVC)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /MP")
endif()


#######################################################################################
# preproc
#######################################################################################
add_definitions(-D_CRT_SECURE_NO_WARNINGS)
add_definitions(-D__STDC_FORMAT_MACROS)
add_definitions(-DBX_CONFIG_ENABLE_MSVC_LEVEL4_WARNINGS=1)
add_definitions(-D__STDC_LIMIT_MACROS)
add_definitions(-D__STDC_CONSTANT_MACROS)
add_definitions(-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS)

#add_definitions(-DCMAKE_CUDA_ARCHITECTURES=75)

add_definitions(-DUSE_DL_PREFIX)
add_definitions(-DGLEW_STATIC)


#######################################################################################
# executable 
#######################################################################################
add_executable( ${EXE_NAME} ${CUDA_SRC_FILES} )
target_compile_features( ${EXE_NAME} PUBLIC cxx_std_11 )
set_target_properties( ${EXE_NAME} PROPERTIES CUDA_SEPARABLE_COMPILATION ON )

# https://cmake.org/cmake/help/git-stage/policy/CMP0104.html
set_property( TARGET ${EXE_NAME} PROPERTY CUDA_ARCHITECTURES 75 ) # Turing = 75

#######################################################################################
# output dirs
#######################################################################################
set_target_properties(${EXE_NAME} PROPERTIES RUNTIME_OUTPUT_DIRECTORY_DEBUG ${CMAKE_SOURCE_DIR}/bin )
set_target_properties(${EXE_NAME} PROPERTIES RUNTIME_OUTPUT_DIRECTORY_RELEASE ${CMAKE_SOURCE_DIR}/bin )
set_target_properties(${EXE_NAME} PROPERTIES RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO ${CMAKE_SOURCE_DIR}/bin )
set_target_properties(${EXE_NAME} PROPERTIES DEBUG_POSTFIX "_d")
set_target_properties(${EXE_NAME} PROPERTIES RELWITHDEBINFO_POSTFIX "RelWithDebInfo")
set_target_properties(${EXE_NAME} PROPERTIES VS_DEBUGGER_WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/bin")

#######################################################################################
# Open the console window in visual studio projects
#######################################################################################
if(MSVC)
    set_target_properties(${EXE_NAME} PROPERTIES LINK_FLAGS_DEBUG "/SUBSYSTEM:CONSOLE")
    set_target_properties(${EXE_NAME} PROPERTIES LINK_FLAGS_RELEASE "/SUBSYSTEM:CONSOLE")
endif()

#######################################################################################
# For reference
#   https://cmake.org/cmake/help/latest/manual/cmake-properties.7.html#target-properties
#######################################################################################

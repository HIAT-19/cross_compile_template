# toolchain-container.cmake
# 
# 用于在容器中进行交叉编译的工具链文件
#
# 需要在交叉编译镜像中指定以下环境变量：
# - SYSTEM_NAME: 系统名称
# - SYSTEM_PROCESSOR: 系统处理器
# - CC: C编译器
# - CXX: C++编译器
# - SYSROOT: sysroot路径

# Asserts
if(NOT DEFINED ENV{SYSTEM_NAME})
    message(FATAL_ERROR "SYSTEM_NAME is not defined, please check your environment variables")
endif()
if(NOT DEFINED ENV{SYSTEM_PROCESSOR})
    message(FATAL_ERROR "SYSTEM_PROCESSOR is not defined, please check your environment variables")
endif()
if(NOT DEFINED ENV{CC})
    message(FATAL_ERROR "CC is not defined, please check your environment variables")
endif()
if(NOT DEFINED ENV{CXX})
    message(FATAL_ERROR "CXX is not defined, please check your environment variables")
endif()
if(NOT DEFINED ENV{SYSROOT})
    message(FATAL_ERROR "SYSROOT is not defined, please check your environment variables")
endif()

# 指定系统名称
set(CMAKE_SYSTEM_NAME $ENV{SYSTEM_NAME})
set(CMAKE_SYSTEM_PROCESSOR $ENV{SYSTEM_PROCESSOR})

# 指定交叉编译器 (在Docker容器中)
set(CMAKE_C_COMPILER $ENV{CC})
set(CMAKE_CXX_COMPILER $ENV{CXX})

# 指定sysroot路径 (在Docker容器中)
set(CMAKE_SYSROOT $ENV{SYSROOT})

# 注入主机侧头文件路径 (由 build.sh 计算并传入)
# 这确保 compile_commands.json 包含主机上的绝对路径，供 clangd 使用
if(DEFINED TOOLCHAIN_HOST_CXX_INCLUDE)
    include_directories(SYSTEM "${TOOLCHAIN_HOST_CXX_INCLUDE}")

    # libstdc++ often requires the target-specific subdir too (e.g. .../c++/aarch64-none-linux-gnu)
    # Without it, clangd may open <vector> but still fail to resolve std::vector.
    file(GLOB _cxx_triple_dirs "${TOOLCHAIN_HOST_CXX_INCLUDE}/*-*-*")
    list(LENGTH _cxx_triple_dirs _len)
    if(_len GREATER 0)
        list(GET _cxx_triple_dirs 0 _triple_dir)
        include_directories(SYSTEM "${_triple_dir}")
    endif()
endif()
if(DEFINED TOOLCHAIN_HOST_SYSROOT_INCLUDE)
    include_directories(SYSTEM "${TOOLCHAIN_HOST_SYSROOT_INCLUDE}")
endif()
if(DEFINED TOOLCHAIN_HOST_GCC_INCLUDE)
    include_directories(SYSTEM "${TOOLCHAIN_HOST_GCC_INCLUDE}")
endif()

# 设置编译器查找路径，确保编译器在sysroot中查找头文件和库
set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})

# 设置查找策略，只在sysroot中查找程序、库和头文件
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# 设置qemu作为模拟器，gtest_discover_tests在运行测试时使用
set(CMAKE_CROSSCOMPILING_EMULATOR /usr/bin/qemu-aarch64 -L ${CMAKE_SYSROOT})

# Dockerfile for RK3588 Cross Compilation (aarch64)

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# 定义工具链的 Git 仓库 URL 和目标安装路径
ARG TOOLCHAIN_REPO="https://github.com/UWVG/aarch64-none-linux-gnu.git"
ARG TOOLCHAIN_INSTALL_DIR="/opt/rk3588/toolchain"

# 1. 安装基础工具（cmake, git, qemu-user 等）
RUN apt update \
    && apt install -y build-essential cmake git qemu-user --fix-missing \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

# 2. 从 Git 仓库克隆交叉工具链
RUN mkdir -p ${TOOLCHAIN_INSTALL_DIR} \
    && git clone --depth 1 ${TOOLCHAIN_REPO} ${TOOLCHAIN_INSTALL_DIR} \
    && rm -rf ${TOOLCHAIN_INSTALL_DIR}/.git
ENV PATH="${TOOLCHAIN_INSTALL_DIR}/bin:$PATH"

# 3. 验证工具链是否安装成功
RUN ${TOOLCHAIN_INSTALL_DIR}/bin/aarch64-none-linux-gnu-gcc --version

# 4. 设置环境变量
ENV SYSTEM_NAME=Linux
ENV SYSTEM_PROCESSOR=aarch64
ENV CC=${TOOLCHAIN_INSTALL_DIR}/bin/aarch64-none-linux-gnu-gcc
ENV CXX=${TOOLCHAIN_INSTALL_DIR}/bin/aarch64-none-linux-gnu-g++
ENV SYSROOT=${TOOLCHAIN_INSTALL_DIR}/aarch64-none-linux-gnu/libc

# --- 关键头文件路径定义 (用于通用 IDE 支持和同步) ---
# 定义 C++ 标准库头文件路径
ENV TOOLCHAIN_CXX_INCLUDE=${TOOLCHAIN_INSTALL_DIR}/aarch64-none-linux-gnu/include/c++/10.2.1
# 定义 目标系统 C 头文件路径 (sysroot include)
ENV TOOLCHAIN_SYSROOT_INCLUDE=${TOOLCHAIN_INSTALL_DIR}/aarch64-none-linux-gnu/libc/usr/include
# 定义 GCC 内置头文件路径
ENV TOOLCHAIN_GCC_INCLUDE=${TOOLCHAIN_INSTALL_DIR}/lib/gcc/aarch64-none-linux-gnu/10.2.1/include

# 5. 设置工作目录
WORKDIR /home/root/project

# 6. 设置默认命令
CMD ["/bin/bash"]


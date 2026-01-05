#!/bin/bash
#
# build.sh - 用于交叉编译和调试脚本
# ----------------------------------------------------------------------

# --- 0. 颜色与日志定义 ---
# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 日志辅助函数
log_info() {
    echo -e "${CYAN}[INFO] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}" >&2
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

log_header() {
    echo -e "\n${BLUE}${BOLD}--- $1 ---${NC}"
}

# -- 1. 读取环境变量 ---

HOST_PROJECT_DIR=$(cd "$(dirname "$0")" && pwd) # 本机项目根目录
HOST_BIN_SUBDIR=${HOST_BIN_SUBDIR:-bin}
CONTAINER_PROJECT_DIR=${CONTAINER_PROJECT_DIR:-$HOST_PROJECT_DIR} # 需要与本机一致，确保 compile_commands.json 可跳转

set -a
if [ -f "${HOST_PROJECT_DIR}/.env" ]; then
    source "${HOST_PROJECT_DIR}/.env"
else
    log_error "未找到 .env 文件。"
    exit 1
fi
set +a

# Defaults (can be overridden by environment or .env)
QEMU_CONTAINER_NAME=${QEMU_CONTAINER_NAME:-qemu-container}
QEMU_DEBUG_CONTAINER_NAME=${QEMU_DEBUG_CONTAINER_NAME:-qemu-container-debug}
QEMU_DEBUG_PORT=${QEMU_DEBUG_PORT:-1234}
DEVICE_LOG_PATH=${DEVICE_LOG_PATH:-/tmp/rk3588_debug.log}

# TOOLCHAIN_HEADERS_DIR 是“IDE 头文件 staging 目录”，仅服务 clangd/代码分析
TOOLCHAIN_HEADERS_DIR=${TOOLCHAIN_HEADERS_DIR:-.toolchain-headers}
TOOLCHAIN_HEADERS_ABS="${HOST_PROJECT_DIR}/${TOOLCHAIN_HEADERS_DIR#./}"

get_image_env() {
    local image="${1:?image required}"
    local key="${2:?key required}"
    docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${image}" 2>/dev/null \
        | awk -F= -v k="${key}" '$1==k {sub($1"=",""); print; exit}'
}

# --- 2. 辅助函数 ---

# 环境配置检查函数
check_environment() {
    log_header "环境配置检查"
    
    local errors=0
    local warnings=0
    
    # 1. 检查 .env 文件
    local env_file="${HOST_PROJECT_DIR}/.env"
    if [ ! -f "$env_file" ]; then
        log_error "未找到 .env 文件"
        ((errors++))
        return 1
    else
        log_success ".env 文件存在"
        # 加载环境变量以便后续检查
        set -a
        source "$env_file" 2>/dev/null || {
            log_error ".env 文件格式错误，无法加载"
            ((errors++))
            set +a
            return 1
        }
        set +a
    fi
    
    # 2. 检查 Docker
    if ! command -v docker >/dev/null 2>&1; then
        log_error "未找到 Docker 命令"
        ((errors++))
    else
        log_success "Docker 已安装: $(docker --version 2>/dev/null | head -1)"
        
        # 检查 Docker 服务是否运行
        if ! docker info >/dev/null 2>&1; then
            log_error "Docker 服务未运行或无权限访问"
            ((errors++))
        else
            log_success "Docker 服务运行正常"
        fi
    fi
    
    # 3. 检查镜像配置
    if [ -z "${CONTAINER_IMAGE_NAME:-}" ]; then
        log_error "CONTAINER_IMAGE_NAME 未在 .env 文件中设置"
        ((errors++))
    else
        log_info "配置的镜像: ${CONTAINER_IMAGE_NAME}"
        
        # 检查镜像是否存在
        if ! docker image inspect "${CONTAINER_IMAGE_NAME}" >/dev/null 2>&1; then
            log_error "Docker 镜像 ${CONTAINER_IMAGE_NAME} 不存在"
            echo "  解决方案:"
            echo "    1. 拉取镜像: docker pull ${CONTAINER_IMAGE_NAME}"
            echo "    2. 或加载镜像: docker load < your-image.tar"
            echo "    3. 或检查镜像名称是否正确"
            ((errors++))
        else
            log_success "镜像 ${CONTAINER_IMAGE_NAME} 存在"
            
            # 检查镜像环境变量
            local cxx_include=$(get_image_env "${CONTAINER_IMAGE_NAME}" TOOLCHAIN_CXX_INCLUDE)
            local sysroot_include=$(get_image_env "${CONTAINER_IMAGE_NAME}" TOOLCHAIN_SYSROOT_INCLUDE)
            
            if [ -z "$cxx_include" ] || [ -z "$sysroot_include" ]; then
                log_error "镜像未定义必要的环境变量"
                echo "  缺失的变量:"
                [ -z "$cxx_include" ] && echo "    - TOOLCHAIN_CXX_INCLUDE"
                [ -z "$sysroot_include" ] && echo "    - TOOLCHAIN_SYSROOT_INCLUDE"
                echo "  解决方案: 确保镜像在构建时定义了这些环境变量"
                echo "    例如在 Dockerfile 中:"
                echo "      ENV TOOLCHAIN_CXX_INCLUDE=/path/to/c++"
                echo "      ENV TOOLCHAIN_SYSROOT_INCLUDE=/path/to/sysroot"
                ((errors++))
            else
                log_success "镜像环境变量配置正确"
                log_info "  TOOLCHAIN_CXX_INCLUDE: $cxx_include"
                log_info "  TOOLCHAIN_SYSROOT_INCLUDE: $sysroot_include"
            fi
        fi
    fi
}

do_setup_env() {
    # 首先进行环境检查
    if ! check_environment; then
        log_error "环境检查失败"
        exit 1
    fi

    log_header "准备交叉编译环境"
    
    local env_file="${HOST_PROJECT_DIR}/.env"
    local marker_start="# === SX ENV VAR ==="
    local marker_end="# === END SX ENV VAR ==="
    local completion_file="${HOST_PROJECT_DIR}/scripts/buildsh_completion.bash"

    if grep -Fq "$marker_start" ~/.bashrc; then
        log_info "检测到旧配置，正在移除..."
        sed -i "/$marker_start/,/$marker_end/d" ~/.bashrc
    fi

    cat <<EOF >> ~/.bashrc

$marker_start
if [ -f "$env_file" ]; then
    # [Current Project: ${HOST_PROJECT_DIR}]
    set -a
    source "$env_file"
    set +a

    export HOST_PROJECT_DIR=${HOST_PROJECT_DIR}
    export HOST_BUILD_DIR_NAME=${HOST_BUILD_DIR_NAME}
    export HOST_BIN_SUBDIR=${HOST_BIN_SUBDIR}
    export CONTAINER_PROJECT_DIR=${CONTAINER_PROJECT_DIR}
    export QEMU_CONTAINER_NAME=${QEMU_CONTAINER_NAME}
    export QEMU_DEBUG_CONTAINER_NAME=${QEMU_DEBUG_CONTAINER_NAME}
    export QEMU_DEBUG_PORT=${QEMU_DEBUG_PORT}
    export DEVICE_LOG_PATH=${DEVICE_LOG_PATH}
fi

# Bash completion for this project (interactive shells only)
# NOTE: keep \$BASH_VERSION and \$- unexpanded here; they must be evaluated when ~/.bashrc is sourced.
if [ -n "\$BASH_VERSION" ] && [[ \$- == *i* ]] && [ -f "${completion_file}" ]; then
    source "${completion_file}"
fi
$marker_end
EOF

    if [ $? -eq 0 ]; then
        log_success "配置已更新为当前项目！"
    else
        log_error "写入 ~/.bashrc 失败。"
        exit 1
    fi

    if ! sync_headers; then
        log_warn "头文件同步失败。如需 clangd 使用 compile_commands.json，请检查 CONTAINER_IMAGE_NAME 以及镜像内 TOOLCHAIN_CXX_INCLUDE / TOOLCHAIN_SYSROOT_INCLUDE / TOOLCHAIN_GCC_INCLUDE。"
    fi

    if [ $? -eq 0 ]; then
        log_success "配置完成"
        echo "请执行: source ~/.bashrc，并重启VSCode编辑器（如果使用VSCode编辑器），以确保环境变量生效。"
    else
        log_error "配置失败"
    fi
}

# 同步头文件到项目目录，用于 clangd 使用 compile_commands.json
sync_headers() {
    if [ -z "${CONTAINER_IMAGE_NAME:-}" ]; then
        log_warn "CONTAINER_IMAGE_NAME 未设置，跳过 sysroot 同步。"
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "未找到 docker 命令，跳过 sysroot 同步。"
        return 0
    fi

    # 1) Read required environment variables from image 
    local src_cxx_include
    local src_sysroot_include
    local src_gcc_include

    src_cxx_include="$(get_image_env "${CONTAINER_IMAGE_NAME}" TOOLCHAIN_CXX_INCLUDE)"
    src_sysroot_include="$(get_image_env "${CONTAINER_IMAGE_NAME}" TOOLCHAIN_SYSROOT_INCLUDE)"
    src_gcc_include="$(get_image_env "${CONTAINER_IMAGE_NAME}" TOOLCHAIN_GCC_INCLUDE)"

    if [ -z "${src_cxx_include}" ] || [ -z "${src_sysroot_include}" ]; then
        log_error "镜像未定义必要的头文件环境变量（TOOLCHAIN_CXX_INCLUDE / TOOLCHAIN_SYSROOT_INCLUDE），无法同步。"
        return 1
    fi

    # 2) Cache: image id
    local image_id
    image_id=$(docker image inspect -f '{{.Id}}' "${CONTAINER_IMAGE_NAME}" 2>/dev/null)
    if [ -z "${image_id}" ]; then
        log_error "无法读取镜像 ID: ${CONTAINER_IMAGE_NAME}"
        return 1
    fi

    mkdir -p "${TOOLCHAIN_HEADERS_ABS}"
    local stamp_file="${TOOLCHAIN_HEADERS_ABS}/.image_id"
    if [ -f "${stamp_file}" ] && [ "$(cat "${stamp_file}")" = "${image_id}" ]; then
        log_info "镜像未变化，跳过头文件同步"
        return 0
    fi

    # 3) Cleanup old artifacts
    # Remove old staging content
    if [[ "${TOOLCHAIN_HEADERS_ABS}" == "${HOST_PROJECT_DIR}/"* ]]; then
        rm -rf "${TOOLCHAIN_HEADERS_ABS:?}/"* "${TOOLCHAIN_HEADERS_ABS:?}/".[!.]* "${TOOLCHAIN_HEADERS_ABS:?}/"..?* >/dev/null 2>&1 || true
    else
        log_warn "staging 目录不在项目目录下，出于安全不自动清空旧内容：${TOOLCHAIN_HEADERS_ABS}"
    fi
    # Remove old legacy dir if present
    if [ -d "${HOST_PROJECT_DIR}/.sysroot" ]; then
        rm -rf "${HOST_PROJECT_DIR}/.sysroot" >/dev/null 2>&1 || true
    fi

    log_info "正在同步头文件到项目目录: ${TOOLCHAIN_HEADERS_ABS} ..."

    local cid
    cid="$(docker create "${CONTAINER_IMAGE_NAME}" sh -lc "true" 2>/dev/null)" || true
    if [ -z "${cid}" ]; then
        log_error "创建临时容器失败: ${CONTAINER_IMAGE_NAME}"
        return 1
    fi

    # 4) Execute sync (flat layout)
    mkdir -p "${TOOLCHAIN_HEADERS_ABS}/c++" "${TOOLCHAIN_HEADERS_ABS}/sysroot" "${TOOLCHAIN_HEADERS_ABS}/gcc"
    
    # Helper function for sync with error handling
    _sync_from_container() {
        local src_path="$1"
        local dst_path="$2"
        local env_name="$3"
        if ! docker cp "${cid}:${src_path}/." "${dst_path}/" >/dev/null 2>&1; then
            docker rm -f "${cid}" >/dev/null 2>&1 || true
            rm -rf "${TOOLCHAIN_HEADERS_ABS}" >/dev/null 2>&1 || true
            log_error "同步失败：${env_name} 路径不存在或不可读：${src_path}"
            return 1
        fi
    }
    
    _sync_from_container "${src_cxx_include}" "${TOOLCHAIN_HEADERS_ABS}/c++" "TOOLCHAIN_CXX_INCLUDE" || return 1
    _sync_from_container "${src_sysroot_include}" "${TOOLCHAIN_HEADERS_ABS}/sysroot" "TOOLCHAIN_SYSROOT_INCLUDE" || return 1
    if [ -n "${src_gcc_include}" ]; then
        _sync_from_container "${src_gcc_include}" "${TOOLCHAIN_HEADERS_ABS}/gcc" "TOOLCHAIN_GCC_INCLUDE" || return 1
    fi

    # 5) Merge architecture-specific files into main directories
    # This is critical for cross-compilation: some key files (e.g., c++config.h)
    # only exist in architecture-specific subdirectories (e.g., aarch64-buildroot-linux-gnu/bits/)
    # but standard headers reference them as <bits/c++config.h>, expecting them in the main bits/ directory.
    log_info "正在合并架构特定目录的关键文件..."
    
    # Helper function to merge architecture-specific subdirectory
    _merge_arch_subdir() {
        local arch_dir="$1"
        local subdir="$2"
        local src_subdir="${arch_dir}/${subdir}"
        local dst_subdir="${TOOLCHAIN_HEADERS_ABS}/c++/${subdir}"
        
        if [ ! -d "${src_subdir}" ]; then
            return 0
        fi
        
        log_info "合并架构目录: $(basename "${arch_dir}")/${subdir}/ -> ${subdir}/"
        find "${src_subdir}" -type f | while IFS= read -r arch_file; do
            local rel_path="${arch_file#${src_subdir}/}"
            local main_file="${dst_subdir}/${rel_path}"
            if [ ! -f "${main_file}" ]; then
                mkdir -p "$(dirname "${main_file}")"
                cp "${arch_file}" "${main_file}" 2>/dev/null || true
            fi
        done
    }
    
    # Find and process architecture-specific directories
    local arch_triple_dirs
    arch_triple_dirs=$(find "${TOOLCHAIN_HEADERS_ABS}/c++" -maxdepth 1 -type d -name "*-*-*" 2>/dev/null)
    if [ -n "${arch_triple_dirs}" ]; then
        while IFS= read -r arch_dir; do
            # Merge common architecture-specific subdirectories
            for subdir in bits ext backward; do
                _merge_arch_subdir "${arch_dir}" "${subdir}"
            done
        done <<< "${arch_triple_dirs}"
    fi

    # Cleanup
    docker rm -f "${cid}" >/dev/null 2>&1 || true
    echo "${image_id}" > "${stamp_file}"
    log_success "头文件同步完成！（已写入 .image_id 缓存）"
    return 0
}

check_docker_image() {
    if ! docker image inspect ${CONTAINER_IMAGE_NAME} > /dev/null 2>&1; then
        log_error "Docker 镜像 ${CONTAINER_IMAGE_NAME} 不存在，请先 pull 或 load。"
        exit 1
    fi
}

check_gdb_multiarch() {
    if ! command -v gdb-multiarch &> /dev/null; then
        log_warn "未找到 'gdb-multiarch' 命令。"
        echo "      请在宿主机上安装：sudo apt install gdb-multiarch" >&2
    fi
}

check_target_exists() {
    if [ ! -f "$1" ]; then
        log_error "未找到文件 $1，请先执行编译命令！"
        exit 1
    fi
}

check_device_connectivity() {
    local target="$DEVICE_SSH_USER@$DEVICE_IP"
    log_info "正在检查设备连接 ($target)..."

    # 尝试以免密方式连接
    if ssh -p "$DEVICE_SSH_PORT" -q -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 "$target" "exit" 2>/dev/null; then
        return 0
    fi

    # 如果失败，进行 ping 测试
    if ! ping -c 1 -W 1 "$DEVICE_IP" >/dev/null 2>&1; then
        log_error "无法 Ping 通设备 ($DEVICE_IP)。请检查网络连接。"
        exit 1
    fi

    # 如果 Ping 通但 SSH 失败，提示配置免密
    log_error "无法通过 SSH 免密连接设备。"
    echo "-------------------------------------------------------"
    echo "请执行以下命令配置免密登录，以便脚本自动化运行："
    echo "  ssh-copy-id -p $DEVICE_SSH_PORT $target"
    echo "-------------------------------------------------------"
    exit 1
}

# --- 3. 核心功能函数 ---

create_debug_container() {
    local port="${1:?port is required}"
    
    check_docker_image

    # Remove existing debug container if any
    docker rm -f "${QEMU_DEBUG_CONTAINER_NAME}" >/dev/null 2>&1 || true

    # Create temporary debug container
    log_info "Creating temporary debug container: ${QEMU_DEBUG_CONTAINER_NAME}"
    docker run -d \
        --name "${QEMU_DEBUG_CONTAINER_NAME}" \
        --env-file "${HOST_PROJECT_DIR}/.env" \
        -u "$(id -u):$(id -g)" \
        -v "${HOST_PROJECT_DIR}:${CONTAINER_PROJECT_DIR}" \
        -w "${CONTAINER_PROJECT_DIR}" \
        -p "${port}:${port}" \
        "${CONTAINER_IMAGE_NAME}" \
        sleep infinity
    
    if [ $? -ne 0 ]; then
        log_error "Failed to create debug container ${QEMU_DEBUG_CONTAINER_NAME}"
        exit 1
    fi
}

run_qemu_in_container() {
    local container_name="${1:?container_name is required}"
    local bin_path="${2:?bin_path is required}"
    local port="${3:?port is required}"
    
    # Kill any existing qemu processes
    docker exec "${container_name}" sh -c "pkill -9 -f qemu-aarch64 || true" >/dev/null 2>&1
    
    # Start qemu in the container (detached, output to container logs)
    local qemu_cmd="/usr/bin/qemu-aarch64 -L \$SYSROOT -g ${port} ${bin_path}"
    log_info "Starting qemu in container: ${qemu_cmd}"
    
    # Start qemu and redirect output to container's stdout (PID 1)
    docker exec -d "${container_name}" \
        /bin/bash -c "${qemu_cmd} > /proc/1/fd/1 2>&1"
    
    if [ $? -ne 0 ]; then
        log_error "Failed to start qemu in container"
        return 1
    fi
    
    return 0
}

do_debug_stop() {
    local dest="docker"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dest) dest="$2"; shift 2;;
            *) shift 1;;
        esac
    done

    case "$dest" in
        docker)
            log_header "停止 Docker 调试环境"
            docker rm -f "${QEMU_DEBUG_CONTAINER_NAME}" >/dev/null 2>&1 || true
            log_info "Debug container removed"
            ;;

        device)
            log_header "停止 Device 调试环境"
            # 远程 kill gdbserver
            ssh -p "$DEVICE_SSH_PORT" -o StrictHostKeyChecking=no "$DEVICE_SSH_USER@$DEVICE_IP" "killall gdbserver" >/dev/null 2>&1 && \
                log_info "已发送终止信号 (killall gdbserver)。" || \
                log_info "设备上未发现运行的 gdbserver 或连接失败。"
            ;;

        *)
            log_error "未知的 dest 类型 '$dest'。请使用 'docker' 或 'device'。"
            exit 1
            ;;
    esac
}

do_debug_logs() {
    local dest="docker"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dest) dest="$2"; shift 2;;
            *) shift 1;;
        esac
    done

    echo "LOG_READY"

    case "${dest}" in
        docker)
            # 清理可能存在的旧日志跟踪进程
            pkill -f "docker logs.*${QEMU_DEBUG_CONTAINER_NAME}" >/dev/null 2>&1 || true

            if ! docker ps --format "{{.Names}}" | grep -q "^${QEMU_DEBUG_CONTAINER_NAME}$"; then
                log_error "容器 ${QEMU_DEBUG_CONTAINER_NAME} 未运行"
                exit 1
            fi

            sleep 0.2

            exec 3< <(docker logs -f "${QEMU_DEBUG_CONTAINER_NAME}" 2>&1 \
                      | grep --line-buffered -v "LOG_READY")
            local LOG_PID=$!

            while IFS= read -r line <&3; do
                echo "$line"
                if [[ "$line" == *"Terminated via GDBstub"* ]]; then
                    kill $LOG_PID >/dev/null 2>&1
                    break
                fi
            done

            exec 3<&-
            exit 0
            ;;

        device)
            check_device_connectivity

            local remote_log="${DEVICE_LOG_PATH}"
            local target="${DEVICE_SSH_USER}@${DEVICE_IP}"

            # 1) 清空日志，避免历史日志干扰
            ssh -p "${DEVICE_SSH_PORT}" -o StrictHostKeyChecking=no "${target}" \
                "sh -lc ': > \"${remote_log}\"'" >/dev/null 2>&1 || true

            # 2) 设备端启动 tail；当 gdbserver 退出后自动停止 tail 并退出
            ssh -p "${DEVICE_SSH_PORT}" -o StrictHostKeyChecking=no "${target}" \
                "sh -lc 'log=\"${remote_log}\"; tail -n 0 -f \"\$log\" & t=\$!; while pgrep gdbserver >/dev/null 2>&1; do sleep 0.2; done; kill \$t >/dev/null 2>&1 || true; wait \$t 2>/dev/null || true'"
            exit 0
            ;;

        *)
            log_error "未知的 dest 类型 '${dest}'。请使用 'docker' 或 'device'。"
            exit 1
            ;;
    esac
}

do_clean() {
    log_header "清理构建产物"
    
    # 简单的安全检查，防止变量未定义删除根目录
    if [ -z "${HOST_BUILD_DIR_NAME}" ]; then
        log_error "变量 HOST_BUILD_DIR_NAME 为空，拒绝执行清理。"
        exit 1
    fi

    local build_dir="${HOST_PROJECT_DIR}/${HOST_BUILD_DIR_NAME}"

    if [ -d "$build_dir" ]; then
        log_info "正在删除目录: ${build_dir} ..."
        rm -rf "${build_dir}" && log_success "清理完成" || { log_error "清理失败"; exit 1; }
    else
        log_warn "目录不存在，无需清理: ${build_dir}"
    fi
}

do_build() {
    local build_type=$1
    check_gdb_multiarch 
    
    local container_build_dir="${CONTAINER_PROJECT_DIR}/${HOST_BUILD_DIR_NAME}"
    log_header "开始 ${build_type} 编译"

    # Detect host-side include paths for clangd (passed to CMake to inject into compile_commands.json)
    # Fail-fast: must have c++ and sysroot staged
    if [ ! -d "${TOOLCHAIN_HEADERS_ABS}/c++" ] || [ ! -d "${TOOLCHAIN_HEADERS_ABS}/sysroot" ]; then
        log_error "未找到头文件 staging 目录：${TOOLCHAIN_HEADERS_ABS}/{c++,sysroot}"
        echo "请先执行: ./build.sh setup-env 并确保镜像已定义 TOOLCHAIN_CXX_INCLUDE / TOOLCHAIN_SYSROOT_INCLUDE" >&2
        exit 1
    fi

    local cmake_extra_args=""
    cmake_extra_args="${cmake_extra_args} -DTOOLCHAIN_HOST_CXX_INCLUDE=${TOOLCHAIN_HEADERS_ABS}/c++"
    cmake_extra_args="${cmake_extra_args} -DTOOLCHAIN_HOST_SYSROOT_INCLUDE=${TOOLCHAIN_HEADERS_ABS}/sysroot"
    if [ -d "${TOOLCHAIN_HEADERS_ABS}/gcc" ] && [ -n "$(ls -A "${TOOLCHAIN_HEADERS_ABS}/gcc" 2>/dev/null)" ]; then
        cmake_extra_args="${cmake_extra_args} -DTOOLCHAIN_HOST_GCC_INCLUDE=${TOOLCHAIN_HEADERS_ABS}/gcc"
    fi

    # Ensure writable dirs for tools inside the container when running as host uid (not root).
    # Buildroot toolchains often enable ccache and default CCACHE_DIR to '/.buildroot-ccache' (not writable).
    local container_ccache_dir="${CONTAINER_PROJECT_DIR}/.ccache"
    local cmd="mkdir -p ${container_build_dir} \"${container_ccache_dir}/tmp\" && cd ${container_build_dir} && \
          cmake .. -DCMAKE_TOOLCHAIN_FILE=${CONTAINER_PROJECT_DIR}/${HOST_TOOLCHAIN_FILE} \
                   -DCMAKE_BUILD_TYPE=${build_type} \
                   -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
                   ${cmake_extra_args} && \
          make -j\$(nproc)"
    
    docker run --rm \
        --env-file "${HOST_PROJECT_DIR}/.env" \
        -e HOME=/tmp \
        -e CCACHE_DIR="${container_ccache_dir}" \
        -e CCACHE_TEMPDIR="${container_ccache_dir}/tmp" \
        -u "$(id -u):$(id -g)" \
        -v "${HOST_PROJECT_DIR}:${CONTAINER_PROJECT_DIR}" \
        -w "${CONTAINER_PROJECT_DIR}" \
        "${CONTAINER_IMAGE_NAME}" \
        /bin/bash -lc "${cmd}"
    
    if [ $? -eq 0 ]; then
        local cc_json="${HOST_PROJECT_DIR}/${HOST_BUILD_DIR_NAME}/compile_commands.json"
        if [ -f "${cc_json}" ]; then
            log_info "创建 compile_commands.json 软链接..."
            ln -sf "${cc_json}" "${HOST_PROJECT_DIR}/compile_commands.json"
        fi
        log_success "编译完成: ${HOST_PROJECT_DIR}/${HOST_BUILD_DIR_NAME}/${build_type}/${HOST_BIN_SUBDIR}/"
    else
        log_error "编译失败"
        exit 1
    fi
}

do_debug_start() {
    local dest=""
    local target=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dest) dest="$2"; shift 2;;
            --target) target="$2"; shift 2;;
            *) shift 1;;
        esac
    done

    if [ -z "${dest}" ] || [ -z "${target}" ]; then
        echo "用法: ./build.sh debug-start --dest <docker|device> --target <name>" >&2; exit 1
    fi

    local port=""
    case "${dest}" in
        docker) port=${QEMU_DEBUG_PORT} ;;
        device) port=${DEVICE_DEBUG_PORT} ;;
        *) log_error "未知 target 类型: ${dest}"; exit 1 ;;
    esac
    
    local type="Debug"
    local bin_rel_path="${HOST_BUILD_DIR_NAME}/${type}/${HOST_BIN_SUBDIR}/${target}"
    local local_bin_path="${HOST_PROJECT_DIR}/${bin_rel_path}"

    check_gdb_multiarch 
    check_target_exists "${local_bin_path}"

    # 1. 停止旧环境 (防止端口冲突)
    do_debug_stop --dest "${dest}"

    log_header "准备启动调试: [${dest}] Mode"

    if [ "${dest}" == "docker" ]; then
        # === Docker 模式 ===

        # Create temporary debug container
        create_debug_container "${port}"
        
        local bin_path="${CONTAINER_PROJECT_DIR}/${bin_rel_path}"
        echo "启动命令: /usr/bin/qemu-aarch64 -L \$SYSROOT -g ${port} ${bin_path}"

        # Start qemu in the temporary debug container
        run_qemu_in_container "${QEMU_DEBUG_CONTAINER_NAME}" "${bin_path}" "${port}"
        
        if [ $? -eq 0 ]; then
            log_success "QEMU_GDBSERVER_READY"
            echo "      监听端口: localhost:${port}"
        else
            log_error "启动 QEMU GDB Server 失败"
            docker rm -f "${QEMU_DEBUG_CONTAINER_NAME}" >/dev/null 2>&1 || true
            exit 1
        fi

    elif [ "${dest}" == "device" ]; then
        # === Device 模式 ===
        
        check_device_connectivity

        log_info "上传程序到设备..."
        echo "       本地: ${local_bin_path}"
        echo "       远程: ${DEVICE_IP}:${DEVICE_BIN_DIR}/${target}"

        ssh -p "$DEVICE_SSH_PORT" "$DEVICE_SSH_USER@$DEVICE_IP" "mkdir -p ${DEVICE_BIN_DIR}"
        scp -P "$DEVICE_SSH_PORT" "${local_bin_path}" "${DEVICE_SSH_USER}@${DEVICE_IP}:${DEVICE_BIN_DIR}/${target}"

        if [ $? -ne 0 ]; then
            log_error "文件上传失败。"
            exit 1
        fi

        log_info "正在设备上启动 gdbserver..."

        # 设备端日志文件路径：用于实时 tail（stdout/stderr 会重定向到该文件）
        local remote_log="${DEVICE_LOG_PATH}"

        # 构造远程命令
        local remote_cmd="chmod +x ${DEVICE_BIN_DIR}/${target} && \
            nohup gdbserver --once :${port} ${DEVICE_BIN_DIR}/${target} > ${remote_log} 2>&1 < /dev/null &"

        timeout 1s ssh -p "$DEVICE_SSH_PORT" "$DEVICE_SSH_USER@$DEVICE_IP" "${remote_cmd}"

        if ssh -p "$DEVICE_SSH_PORT" "$DEVICE_SSH_USER@$DEVICE_IP" "pgrep gdbserver > /dev/null"; then
            log_success "DEVICE_GDBSERVER_READY"
            echo "       设备 IP: ${DEVICE_IP}"
            echo "       监听端口: ${port}"
            echo "       目标程序: ${DEVICE_BIN_DIR}/${target}"
        else
            log_error "启动失败！gdbserver 进程未存活。"
            echo "       可能是缺少动态库或架构不匹配。远程日志如下："
            echo "-------------------------------------------------------"
            ssh -p "$DEVICE_SSH_PORT" "$DEVICE_SSH_USER@$DEVICE_IP" "cat ${remote_log}"
            echo "-------------------------------------------------------"
            exit 1
        fi
    fi

    echo "-------------------------------------------------------"
    echo "Hint: run './build.sh debug-stop --dest ${dest}' to cleanup after debugging."
    echo "-------------------------------------------------------"
}

show_help() {
    echo "用法: ./build.sh <command> [options]"
    echo ""
    echo "常用命令:"
    echo "  setup-env          写入环境变量到 ~/.bashrc，并同步头文件到项目目录"
    echo "  clean              删除构建目录: ${HOST_PROJECT_DIR}/${HOST_BUILD_DIR_NAME}"
    echo "  debug              构建 Debug 版本"
    echo "  release            构建 Release 版本"
    echo ""
    echo "调试相关:"
    echo "  debug-start        启动调试，会在目标 (container/device) 上启动 gdbserver 或 qemu-gdbstub"
    echo "                     参数: --dest <docker|device> --target <binary_name>"
    echo "                     注意: docker 模式默认使用本地端口 ${QEMU_DEBUG_PORT}; device 模式使用环境变量 DEVICE_DEBUG_PORT"
    echo "  debug-stop         停止调试，参数: --dest <docker|device> （默认: docker）"
    echo "  debug-logs         跟随调试日志，参数: --dest <docker|device> （默认: docker）"
    echo ""
    echo "帮助:"
    echo "  -h, --help, help   显示本帮助信息"
    echo ""
    echo "示例:"
    echo "  ./build.sh clean"
    echo "  ./build.sh debug-start --dest device --target myapp"
    echo "  ./build.sh debug-logs --dest docker"
    echo "  ./build.sh debug-logs --dest device"
}

# --- 4. 入口 ---

COMMAND=$1
if [ -z "$COMMAND" ]; then show_help; exit 0; fi
shift

case "$COMMAND" in
    setup-env)   do_setup_env ;;
    clean)       do_clean ;; 
    debug)       do_build "Debug" ;;
    release)     do_build "Release" ;;
    debug-start) do_debug_start "$@" ;;
    debug-stop)  do_debug_stop "$@" ;;
    debug-logs)  do_debug_logs "$@" ;;
    help|--help|-h) show_help ;;
    *) log_error "未知命令: $COMMAND"; show_help; exit 1 ;;
esac


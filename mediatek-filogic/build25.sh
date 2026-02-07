#!/bin/bash
source shell/custom-packages.sh
# 该文件实际为imagebuilder容器内的build.sh

echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

# 拷贝 run/arm64 下所有 run 文件和ipk文件 到 extra-packages 目录
mkdir -p /home/build/immortalwrt/extra-packages
cp -r /tmp/store-run-repo/run/arm64/* /home/build/immortalwrt/extra-packages/

echo "✅ Run files copied to extra-packages:"
ls -lh /home/build/immortalwrt/extra-packages/*.run

# 解压并拷贝ipk到packages目录
sh shell/prepare-packages.sh
echo "📦 Checking packages directory:"
ls -lah /home/build/immortalwrt/packages/

# -------------------------------------------------------------------------
# [适配 25.12 核心修复 V4 - 绝对路径修复]
# 1. 获取 apk 的绝对路径，防止 cd 后失效
# 2. 设置 LD_LIBRARY_PATH 为绝对路径
# -------------------------------------------------------------------------
echo "⚡️ Generating APK index for local packages..."

# 1. 寻找 apk 二进制文件 (获取绝对路径)
APK_BIN=""
if [ -f "staging_dir/host/bin/apk" ]; then
    # 使用 $(readlink -f ...) 获取绝对路径
    APK_BIN=$(readlink -f "staging_dir/host/bin/apk")
else
    # 搜索并获取绝对路径
    APK_BIN=$(find "$(pwd)/staging_dir" -name apk -type f -executable | head -n 1)
fi

if [ -z "$APK_BIN" ]; then
    echo "❌ Critical Error: Could not find 'apk' binary in ImageBuilder!"
    exit 1
else
    echo "✅ Found apk binary at absolute path: $APK_BIN"
fi

# 2. 设置动态库路径 (使用绝对路径)
# 获取 apk 所在目录的父目录的 lib 目录 (即 staging_dir/host/lib)
APK_DIR=$(dirname "$APK_BIN")
LIB_DIR="$(dirname "$APK_DIR")/lib"

if [ -d "$LIB_DIR" ]; then
    export LD_LIBRARY_PATH="$LIB_DIR:$LD_LIBRARY_PATH"
    echo "🔧 Set LD_LIBRARY_PATH to: $LD_LIBRARY_PATH"
else
    echo "⚠️ Warning: Library directory $LIB_DIR not found, apk might fail."
fi

# 3. 生成索引
if [ -d "/home/build/immortalwrt/packages" ]; then
    cd /home/build/immortalwrt/packages
    
    rm -f packages.adb
    
    count=$(ls *.ipk 2>/dev/null | wc -l)
    if [ "$count" != "0" ]; then
        echo "   ... indexing $count packages"
        
        # 使用绝对路径执行 apk
        "$APK_BIN" index -o packages.adb *.ipk
        EXIT_CODE=$?
        
        if [ $EXIT_CODE -eq 0 ] && [ -f "packages.adb" ]; then
            echo "✅ APK index generated successfully."
        else
            echo "❌ Error: 'apk index' failed with code $EXIT_CODE"
            echo "🔍 Debugging dependencies for apk binary:"
            ldd "$APK_BIN"
            exit 1
        fi
    else
        echo "⚠️ Warning: No .ipk files found, skipping index."
    fi
    
    # 注册本地源
    echo "/home/build/immortalwrt/packages" >> /etc/apk/repositories
    echo "✅ Added local repo to /etc/apk/repositories"
    
    cd - > /dev/null
else
    echo "❌ Error: Packages directory not found!"
    exit 1
fi
# -------------------------------------------------------------------------

# yml 传入的路由器型号 PROFILE
echo "Building for profile: $PROFILE"
echo "Include Docker: $INCLUDE_DOCKER"
echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting build process..."

# 定义所需安装的包列表
PACKAGES=""
PACKAGES="$PACKAGES curl luci luci-i18n-base-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# 第三方软件包 合并
if [ "$PROFILE" = "glinet_gl-axt1800" ] || [ "$PROFILE" = "glinet_gl-ax1800" ]; then
    echo "Model:$PROFILE not support third-parted packages"
    PACKAGES="$PACKAGES -luci-i18n-diskman-zh-cn luci-i18n-homeproxy-zh-cn"
else
    echo "Other Model:$PROFILE"
    PACKAGES="$PACKAGES $CUSTOM_PACKAGES"
fi

# Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# OpenClash 内核下载
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

# -------------------------------------------------------------------------
# [适配 25.12]
# 使用 APK_FLAGS="--allow-untrusted --force-broken-world"
# 注入 PATH (使用 APK_DIR 的绝对路径)
# -------------------------------------------------------------------------
export PATH="$APK_DIR:$PATH"
echo "🔧 Updated PATH: $PATH"

make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" APK_FLAGS="--allow-untrusted --force-broken-world"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."

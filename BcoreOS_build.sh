#!/bin/sh
# ==============================================================================
# BcoreOS_build: 跨异构硬件与发行版中立的元操作系统(Meta-OS)自动构建流水线
#    1,生成与之配套的500M dd初始安装镜像AOS;
#    2,生成包含引导+内核+initrd+根文件系统的BcoreOS升级包;
#
# [双态交付物生成规约 (Deliverables Specification)]
# ------------------------------------------------------------------------------
# 1. AOS (Abstraction & Adaptation OS) 初始安装基盘:
#    - 封装为 500MB 精炼原始块设备镜像 (.dd)。
#    - 宿主常驻层：集成通用 Mainline 驱动网与存储，对外物理屏蔽硬件差异。
# 2. BcoreOS 盲盒业务全量升级包 (.upt):
#    - 采用单体原子包裹(Combined Payload)，内聚打入：引导器(GRUB)、同源内核、
#      应用根文件系统，以及与之深度绑定的孪生 AOS 镜像。
#    - 100% 字节对齐：确保实验室内测 VM 与远程生产设备运行环境（C库/二进制/应用驱动）绝对一致。
#
# [零媒介现场灌装与网络继承规约 (Bare-Metal & In-Place Deployment)]
# ------------------------------------------------------------------------------
# 1. 裸机/无系统主机初次部署:
#    - 支持通过通用 WinPE 工具、Live Linux 分发版以秒级裸块物理灌装 (dd) 至目标磁盘。
# 2. 存量存活 Linux 主机就地盲刷 (Live OS In-place Overwrite):
#    - 提供极简部署脚本 `BcoreOS_install`，允许直接通过 SSH 以 Root 权限就地强刷。
#    - 网络继承：自动继承原主机的物理网卡 IP、掩码、网关与路由。
#
# [BcoreOS 跨发行版原子无感升级规约 (Cross-Distribution Upgrades)]
# ------------------------------------------------------------------------------
# 1. 极简应用流程:
#    - 运维或前线测试人员通过 AOS 提供的标准 Web 控制台或客户端工具，一键上传 `bcoreos.upt` 固件。
# 2. 孪生底座绝对对齐与链式交接机制 (Two-Phase Absolute Alignment & Chained Lifecycle):
#    - 阶段一 (底座强行对齐)：BcoreOS 升级包内包含一个完整的物理 AOS。系统接收到升级包后，首先在后台对
#      目标机当前的常驻 AOS 与升级包内的 AOS 执行「二进制现场哈希比对 (SHA256)」。
#      若二进制数据 100% 相同，则跳过此步；若不一致，系统直接执行物理全量覆盖升级，强制把当前底座替换。
#    - 阶段二 (无感切根契约)：只有在目标机 AOS 与升级包内 AOS 达到 100% 二进制绝对状态对齐后，AOS 
#      才激活业务层交接契约。由该 AOS 完成BoreOS部分的二进制对其，在初始化网络和磁盘后，将标准化环境硬注入给 BcoreOS。
#    - 结果：彻底斩断发行版底层冲突。实现 RHEL 10 & Ubuntu 在不相互理解、不需要对方包管理器和内核驱动
#      参与的极端情况下，达成 100% 安全、秒级自愈回退的原子换代。
#
# [BcoreOS 极限安全防御设计规约 (Fail-Safe & Defensive Design)]
# ------------------------------------------------------------------------------
# 1. 物理层抗掉电高内聚保护:
#    - 存储架构采用工业级 A/B 槽位（Dual-Slot）双物理根设计。升级包的写入、解压、校对全量在后台
#      向备份系统（闲置槽位）静默执行，过程中绝对不破坏、不修改当前正在平稳运行的原主系统。
#    - 100% 物理抗掉电：在写入、灌装期间任何一秒发生突发断电、物理拔电，原 Slot 系统毫无损伤，重启即复原。
# 2. 控制面“影子尝试启动”机制 (Trial Boot with Heartbeat Watchdog):
#    - 新系统灌装就绪后，AOS 绝不立即执行永久性引导切换，而是将新 Slot 标记为“影子尝试启动（Trial Boot）”状态。
#    - 触发全自动超时闭环计数。如果新系统由于未知的异构硬件不兼容、内核恐慌或驱动冲突导致卡死，
#      系统会在规定时间超时后自动强行触发硬重启，完美无感回退老系统。
# 3. 闭环主动确认机制 (Active Confirmation Telemetry):
#    - 新系统影子启动成功、网络直通、业务上线后，必须由升级发起者（Web 端，或客户端
#      工具）在预设的时间窗口内执行进行确认「比如检查版本的这个实质网络动作」。
#    - 逾期未达则自毁：若时间窗口内未收到升级发起者的确认信号，aos 判定业务运行异常，直接拒绝固化，
#      自动触发软重启并强制回退至原 Slot，将“盲盒换系统”的试错成本降为零。
# 4. 生产现场“无备用测试硬件”的极限越级调试:
#    - 该安全机制允许操作人员在没有任何多余测试备机、没有任何本地救援介质的情况下，直接把唯一的生产物理机
#      当做实验沙盒进行跨大版本盲刷调测。在新系统不兼容时退回老版本，保障生产设备永远不失联成砖。
# ==============================================================================

support_url="https://github.com/acode001/BcoreOS"
thisDir=$(cd "$(dirname "$0")" && pwd)
aosDir="$thisDir"
if [ "${thisDir##*/}" != "aos" ]; then aosDir="$thisDir/aos";fi
kernel_path=""
aosImg=""
aosVersion="0.0"
BcoreOSTag=""
outputName=""
outputAOS=""
outputBcoreOS=""
get_command_path_to_var() {
    local cmd="$1"
    local __result_var="$2"
    eval "$__result_var=\"\""
    local dir
    for dir in /usr/bin /usr/sbin /bin /sbin; do
        if [ -x "$dir/$cmd" ]; then
            eval "$__result_var=\"$dir/$cmd\""
            break
        fi
    done
}
# 检查需要的工具是否存在
check_tool(){
REQUIRED_CMDS="dd gzip md5sum kill ln mkdir pwd sort tail tr wait wget"
for cmd in $REQUIRED_CMDS; do
    local realPath=""
    get_command_path_to_var "$cmd" "realPath"
    if [[ -z "$realPath" ]]; then
        echo " [ERROR] Missing critical maintenance tool in PATH: $cmd"
        exit 1
    fi
done
}
# ini 读取
ini_read() {
    local file="$1"
    local section="$2"
    local key="$3"
    [ -s "$file" ] || return 0
    awk -F '=' \
        -v sec="[$section]" -v k="$key" \
        '
        $0 ~ "^[ \t]*\\[" && $0 ~ sec { f=1; next }
        $0 ~ "^[ \t]*\\[" { f=0 }
        f {
            gsub(/^[ \t]+|[ \t]+$/, "", $1)
            if ($1 == k) {
                gsub(/^[ \t]+|[ \t\r\n]+$/, "", $2)
                print $2
                exit
            }
        }
        ' "$file" 2>/dev/null
}
# 读取历史配置
load_config() {
    aosImg=$(ini_read "$aosDir/config" "config" "aosImg")
    BcoreOSTag=$(ini_read "$aosDir/config" "config" "BcoreOSTag")
    outputName=$(ini_read "$aosDir/config" "config" "outputName")
}
download_file() {
    local rel_path="$1"   # 相对路径（相对于基础 URL）
    local dest="$2"       # 本地保存路径
    local urls
    # 定义 URL 基础路径
    urls=(
        "http://10.172.100.80/"
        "http://10.172.100.82/"
        "http://mirror.example.com/"
    )

    # 拼接完整 URL
    for i in "${!urls[@]}"; do
        urls[$i]="${urls[$i]}$rel_path"
    done
    # 打乱 URL 顺序，随机尝试
    urls=($(printf "%s\n" "${urls[@]}" | shuf))
    mkdir -p "${dest%/*}"
    if [ -e "$dest" ];then rm -f "$dest";fi
    for url in "${urls[@]}"; do
        echo "Trying to download from: $url"
        wget -O "$dest" --timeout=10 --tries=2 --show-progress "$url"
        if [ $? -eq 0 ]; then
            echo "Download succeeded: $dest"
            return 0
        else
            echo "Failed to download from: $url"
        fi
    done
    echo "[ERROR] All URLs failed for $rel_path. Exiting."
    exit 1
}
# Returns 0 if equal (ignoring case), returns 1 otherwise
compare_ignore_case() {
    local str1="$1"
    local str2="$2"

    # 1. Check if physical lengths match first to save performance
    if [ "${#str1}" -ne "${#str2}" ]; then
        return 1
    fi

    local i=0
    local len="${#str1}"

    # 2. Traditional pointer loop: move character by character
    while [ "$i" -lt "$len" ]; do
        # Traditional memory slicing: extract the single character at index i
        local c1="${str1:$i:1}"
        local c2="${str2:$i:1}"

        # 3. Core mechanism: map uppercase characters to lowercase using case branches
        #    Completely auditable, zero external binary dependency
        case "$c1" in
            A) c1="a" ;; B) c1="b" ;; C) c1="c" ;; D) c1="d" ;; E) c1="e" ;;
            F) c1="f" ;; G) c1="g" ;; H) c1="h" ;; I) c1="i" ;; J) c1="j" ;;
            K) c1="k" ;; L) c1="l" ;; M) c1="m" ;; N) c1="n" ;; O) c1="o" ;;
            P) c1="p" ;; Q) c1="q" ;; R) c1="r" ;; S) c1="s" ;; T) c1="t" ;;
            U) c1="u" ;; V) c1="v" ;; W) c1="w" ;; X) c1="x" ;; Y) c1="y" ;;
            Z) c1="z" ;;
        esac

        case "$c2" in
            A) c2="a" ;; B) c2="b" ;; C) c2="c" ;; D) c2="d" ;; E) c2="e" ;;
            F) c2="f" ;; G) c2="g" ;; H) c2="h" ;; I) c2="i" ;; J) c2="j" ;;
            K) c2="k" ;; L) c2="l" ;; M) c2="m" ;; N) c2="n" ;; O) c2="o" ;;
            P) c2="p" ;; Q) c2="q" ;; R) c2="r" ;; S) c2="s" ;; T) c2="t" ;;
            U) c2="u" ;; V) c2="v" ;; W) c2="w" ;; X) c2="x" ;; Y) c2="y" ;;
            Z) c2="z" ;;
        esac

        # 4. Verification: if the characters do not match, abort immediately
        if [ "$c1" != "$c2" ]; then
            return 1
        fi

        # Traditional counter increment
        i=$((i + 1))
    done
    return 0 # All characters matched successfully
}
# 获取内核路径 
kernelPath_get(){
    boot_image=""
    while read -r param; do
        for p in $param; do
            case $p in
                BOOT_IMAGE=*)
                    boot_image="${p#BOOT_IMAGE=}"
                    ;;
            esac
        done
    done < /proc/cmdline
    boot_image="/${boot_image#*/}"
    kernel_path="$boot_image"
    if [ ! -e "$kernel_path" ];then kernel_path="/boot$boot_image";fi
    if [ ! -e "$kernel_path" ];then  echo "[ERROR] Failed to find kernel: $kernel_path. Please contact us at $support_url.";exit 1;fi
}
# 获取本地AOS镜像文件 
get_imgs_from_local(){
    local kernel_md5sum="$1"
    local -n l_fileList="$2"
    local rawList=()
    for file in "$aosDir"/*.img.gz; do
        if [ -f "$file" ] && [ ! -L "$file" ]; then
            local kernelhash="${file##*/}"
            kernelhash="${kernelhash#*-}"
            kernelhash="${kernelhash#*-}"
            kernelhash="${kernelhash#*-}"
            kernelhash="${kernelhash%%-*}"
            if compare_ignore_case "$kernel_md5sum" "$kernelhash"; then
               rawList+=("$file")
            fi
        fi
    done
    l_fileList=()
    if [ ${#rawList[@]} -eq 0 ]; then
        return 0
    fi
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            l_fileList+=("$line")
        fi
    done < <(printf '%s\n' "${rawList[@]}" | sort -Vr)
}
# 准备aos系统
prepare_aos(){
    # 镜像:内核md5sum aos的md5sum 版本信息
    imgs=(
        "4070e7f10398bb2e4688ba1d9a877519 30A1039187755E5E1DFF797C1B3CAFC1 AOS-6.223.3068_for_rocky10.1(6.12.0-124.8.1.el10_1.x86_64)"
        "4070e7f10398bb2e4688ba1d9a877519 96462AF584A3A42720BBECC808FB4C71 AOS-6.223.2178_for_rocky10.1(6.12.0-124.8.1.el10_1.x86_64)"
    )
    kernel_md5sum=$(md5sum "$kernel_path")
    kernel_md5sum="${kernel_md5sum%% *}" 
    matches=()
    for img in "${imgs[@]}"; do
        first_md5="${img%% *}"
        if [ "$first_md5" = "$kernel_md5sum" ]; then
            matches+=("$img")
        fi
    done
    local fileList=()
    get_imgs_from_local $kernel_md5sum fileList
    fileList_count=${#fileList[@]}
    match_count=${#matches[@]}
    if [  "$((match_count + fileList_count))" -gt 0 ]; then
        echo "Available AOS versions for BoreOS($kernel_path):"
        options=()
        for m in "${fileList[@]}"; do
            options+=("$m")
        done
        for m in "${matches[@]}"; do
            cache_md5sum="${m#* }"
            cache_md5sum="${cache_md5sum%% *}"
            cache_path="$aosDir/aos-$cache_md5sum"
            actual_md5=""
            if [ -e "$cache_path" ];then
                actual_md5=$(md5sum "$cache_path")
                actual_md5="${actual_md5%% *}"
            fi
            third="${m#* * }"
            if compare_ignore_case "$cache_md5sum" "$actual_md5"; then
                options+=("$third (already downloaded at: $cache_path)")
            else
                options+=("$third (not downloaded yet)")
            fi
        done
        for i in "${!options[@]}"; do
            printf "%d) %s\n" $((i+1)) "${options[i]}"
        done
        default=1
        for i in "${!fileList[@]}"; do
            if [ "$i" = "$aosImg" ]; then
                default=$((i + 1))
                break
            fi
        done
        for i in "${!imgs[@]}"; do
            second=$(echo "${imgs[$i]}" | awk '{print $2}')
            if [ "$aosDir/aos-$second" = "$aosImg" ]; then
                default=$((i + 1))
                break
            fi
        done
        read -p "Select [1-${match_count}] (default ${default}): " choice
        choice=${choice:-$default}
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$((match_count + fileList_count))" ]; then
            choice=1
        fi
        selected_aos="${options[$((choice-1))]}"
        {
            max=0
            for x in ${selected_aos//[-_]/ }; do
                if [[ "$x" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
                    n=${x//[^.]}
                    if ((${#n} > max)); then
                        max=${#n}
                        aosVersion="$x"
                    fi
                fi
           done
        }
        if [ "$choice" -le "$fileList_count" ];then
            aosImg="${fileList[$((choice - 1))]}"
        else
            img="${matches[$((choice - fileList_count - 1))]}"
            cache_md5sum="${img#* }"
            cache_md5sum="${cache_md5sum%% *}"
            cache_path="$aosDir/aos-$cache_md5sum"
            actual_md5=""
            if [ -e "$cache_path" ];then
                actual_md5=$(md5sum "$cache_path")
                actual_md5="${actual_md5%% *}"
            fi
            if ! compare_ignore_case "$cache_md5sum" "$actual_md5"; then
                download_file "aos/aos-$cache_md5sum"  "$cache_path"
                actual_md5=$(md5sum "$cache_path")
                actual_md5="${actual_md5%% *}"
                if ! compare_ignore_case "$cache_md5sum" "$actual_md5"; then
                    echo "Invalid AOS image: ${img#* * }. Please contact us at $support_url."
                    exit 1
                fi
            fi
            aosImg="$cache_path"
        fi
        return 0
    else
        echo "No AOS version supports this kernel: $kernel_path. Please contact us at $support_url."
        echo "Supported AOS versions are:"
        for m in "${imgs[@]}"; do
            third="${m#* * }"
            echo "  $third"
        done
        exit 1
    fi
}
# 设置BcoreOS标记
set_BcoreOSTag(){
    if [ -z "$BcoreOSTag" ]; then
        BcoreOSTag="BcoreOS"
    fi
    echo -e "\n[BcoreOS WARNING] Modifying this value breaks package universality and blocks open sharing."
    echo "                  Customized private tagging strictly requires a commercial license."
    echo "                  If changed without proper alignment, the update package WILL NOT WORK."
    read -e -i "$BcoreOSTag" -p "change BcoreOS tag (tags must match to allow update): " choice
    choice="${choice//[[:space:]]/}"
    if [ -n "$choice" ]; then
        BcoreOSTag="$choice"
    else
        BcoreOSTag="BcoreOS"
        echo -e "\n[BcoreOS Warning] Tag cannot be empty. Reverting to default: $BcoreOSTag"
    fi
}
get_output_name(){
    local distro="unknown"
    local version=""
    local line=""

    # --------------------------------------------------------------------------
    # 🌟 标准 /etc/os-release (纯 Shell 内置流式精确抓取)
    # --------------------------------------------------------------------------
    if [ -s /etc/os-release ]; then
        while read -r line || [ -n "$line" ]; do
            # 1. 精准截取等号右边的 ID
            if [[ "$line" =~ ^ID= ]]; then
                distro="${line#*=}"
                distro="${distro//[\"\']/}"
                distro="${distro// /}"
            fi
            # 2. 精准截取等号右边的准确 VERSION_ID
            if [[ "$line" =~ ^VERSION_ID= ]]; then
                version="${line#*=}"
                version="${version//[\"\']/}"
                version="${version// /}"
            fi
        done < /etc/os-release

        # 针对红帽系及衍生商业系统进行血统规范化
        if [ "$distro" = "rhel" ] || [ "$distro" = "ol" ]; then
            distro="rhel"
        fi

    # --------------------------------------------------------------------------
    # 🧱 旧红帽系 / 商业特殊系统的“历史古董通道” (CentOS 5/6/7)
    # --------------------------------------------------------------------------
    elif [ -s /etc/redhat-release ]; then
        read -r line < /etc/redhat-release
        line="${line,,}"  # 内存级转换为纯小写
        
        if [[ "$line" == *"centos"* ]]; then
            distro="centos"
        elif [[ "$line" == *"rocky"* ]]; then
            distro="rocky"
        else
            distro="rhel"
        fi

        # 纯原生精准剥离提取数字：利用通配符截取发行版关键字后面的准确数字
        local tmp="${line##*release }"
        [ "$tmp" = "$line" ] && tmp="${line##*version }"
        # 去除数字后面的所有尾随非数字杂音（如截取 7.9.2009 (core) 得到 7.9.2009）
        version="${tmp%% *}"

    # --------------------------------------------------------------------------
    # 📡 老 Debian 系 / 纯净野生社区版遗留机
    # --------------------------------------------------------------------------
    elif [ -s /etc/debian_version ]; then
        distro="debian"
        read -r version < /etc/debian_version
        version="${version// /}"
    fi

    # --------------------------------------------------------------------------
    # 🧠 对提取结果进行“绝对准确净化”
    # --------------------------------------------------------------------------
    # 1. 强行拉平系统名大小写
    distro="${distro,,}"
    
    # 2. 【核心修改】去除由于部分发行版带有的多余末尾小版本号（例如把 22.04.4 精准净化为 22.04）
    # 保持主+次版本号的最高准确度，且不使用 cut 命令。
    local clean_version="$version"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        # 如果是三段式（如 10.2.1），剥离最后一段点和数字，变成 10.2
        clean_version="${version%.*}"
    fi

    # 3. 终极自愈：如果版本为空，强行注入安全兜底
    [ -z "$clean_version" ] && clean_version="unknown"

    # 4. 完美输出包含【准确版本号】的唯一血统标签 (如: rocky10.2, ubuntu22.04, centos7.9)
    echo "${distro}${clean_version}"
}
# 设置输出名字
set_output_name(){
    if [ -z "$outputName" ]; then
        outputName=$(get_output_name)-$(date +%Y%m%d)
    fi
    read -e -i "$outputName" -p "change output name: " choice
    choice="${choice//[[:space:]]/}"
    if [ -n "$choice" ]; then
        outputName="$choice"
    else
        outputName=$(get_output_name)-$(date +%Y%m%d)
        echo -e "\n[Output name Warning] outputName cannot be empty. Reverting to default: $outputName"
    fi
}
# 准备打包工具
prepare_ptool(){
    #读取keyData
    local keyData=""
    local aosImgPath="$aosDir/aosImg"
    {
        gzip -cd $aosImg > "$aosImgPath"
        local size=64
        while true; do
            local BLOCK=$(tail -c $size "$aosImgPath" | tr -d '\000')
            if echo "$BLOCK" | grep -Fq "["; then
                keyData="${BLOCK##*\[}"
                break
            fi
            if [ $size -gt 10123123 ]; then
                break
            fi
            size=$((size * 2))
        done
    }
    if [[ "$keyData" != *\] ]]; then
        echo "Invalid img: $aosImg. Please contact us at $support_url."
        exit 1   
    fi
    keyData="${keyData%\]}"
    #echo  "keyData:$keyData"
    local ptool="$aosDir/ptool"
    > "$ptool"
    IFS=' ' read -r -a NUMS <<< "$(echo "$keyData" | tr ',' ' ')"
    TOTAL_ELEMENTS=${#NUMS[@]}
    local CURRENT_SEEK=0
    for ((i=0; i<TOTAL_ELEMENTS; i+=2)); do
        OFFSET=${NUMS[i]}
        SIZE=${NUMS[i+1]}
        local COMBINED=$(( OFFSET | CURRENT_SEEK | SIZE ))
        local BS=$(( COMBINED & -COMBINED ))
        if [ $BS -gt 131072 ]; then
            local BS=131072
        fi
        local FILE_SKIP=$(( OFFSET / BS ))
        local FILE_COUNT=$(( SIZE / BS ))
        local FILE_SEEK=$(( CURRENT_SEEK / BS ))
        dd if="$aosImgPath" of="$ptool" bs=$BS skip=$FILE_SKIP count=$FILE_COUNT seek=$FILE_SEEK status=none conv=notrunc 2>/dev/null
        CURRENT_SEEK=$((CURRENT_SEEK + SIZE))
    done
    rm -f "$aosImgPath"
}
# 在initrd中插入脚本重启完成系统打包,生成升级包和安装包
patch_initrd(){
    local initrd_file="$1"
    local filename="${initrd_file##*/}"
    local name_without_ext="${filename%.img}"
    local tmpDir="$aosDir/$name_without_ext"
    if [ -d "$tmpDir" ];then return;fi
    mkdir $tmpDir
    local olddir=$(pwd)
    cd $tmpDir
    if [ -f /usr/lib/dracut/skipcpio ];then
        /usr/lib/dracut/skipcpio "$initrd_file" >"$tmpDir/initrd"
    else
       \cp "$initrd_file" "$tmpDir/initrd"
    fi
    # 解压
    local fileType="error"
    {
        local file_mime=$(file --mime-type -b "$tmpDir/initrd")
        if [ "$file_mime" = "application/gzip" ] || [ "$file_mime" = "application/x-gzip" ]; then
            fileType="gzip"
            gzip -cd "$tmpDir/initrd" | cpio -idm --quiet
        elif [ "$file_mime" = "application/zstd" ] || [ "$file_mime" = "application/x-zstd" ]; then
            fileType="zstd"
            zstd -cd "$tmpDir/initrd" | cpio -idm --quiet
        fi
        rm -rf "$tmpDir/initrd"
    }
    local patched=0
    # 拷贝命令 
    {
        REQUIRED_CMDS="gzip cpio"
        for cmd in $REQUIRED_CMDS; do
            local realPath=""
            get_command_path_to_var "$cmd" "realPath"
            if [[ -z "$realPath" ]]; then
                echo " [ERROR] Missing critical maintenance tool in PATH: $cmd"
            elif [[ ! -e "$tmpDir/$realPath" ]] ;then
                \cp -a "$realPath" "$tmpDir/$realPath"
                patched=1;
            fi
        done
    }
    # 拷贝工具
    {
        local ptool_md5="1";
        local ptool_real_md5="2";
        if [[ -e "$tmpDir/ptool" ]];then
            ptool_md5=$(md5sum "$tmpDir/ptool");
            ptool_real_md5=$(md5sum "$aosDir/ptool");
        fi
        if [[ $ptool_md5 != $ptool_real_md5 ]];then
            \cp -a "$aosDir/ptool" "$tmpDir/ptool"
            patched=1;
        fi
    }
    # 修改脚本
    {
        local target_service_path="$tmpDir/usr/lib/systemd/system/BcoreOS_build.service"
        local cmd="/bin/sh -c \"mkdir /pDir && cd /pDir;gzip -d -c /ptool |cpio -idm 2>/dev/null;/pDir/tmp/systemLoad p3img > /dev/shm/p3img.log 2>&1\""
        local service_content="[Unit]
Description=Service for generating BcoreOS installation and upgrade packages
DefaultDependencies=no
After=initrd-root-fs.target
Before=initrd-switch-root.target
IgnoreOnIsolate=true
ConditionPathExists=!/sysroot$outputBcoreOS
[Service]
Type=oneshot
ExecStart=$cmd
TimeoutSec=0
RemainAfterExit=yes
[Install]
WantedBy=initrd-switch-root.target"
        local need_write=1
        if [[ -f "$target_service_path" ]]; then
            local file_content=$(cat "$target_service_path")
            if [[ "$file_content" == "$service_content" ]]; then
                need_write=0
            fi
        fi
        if [[ $need_write -eq 1 ]];then
            printf '%s\n' "$service_content" > "$target_service_path"
            patched=1; 
        fi
        local service_filename="${target_service_path##*/}"
        local wants_dir="$tmpDir/usr/lib/systemd/system/initrd-switch-root.target.wants"
        local link_path="$wants_dir/$service_filename"
        local target_abs_path="$tmpDir/usr/lib/systemd/system/$service_filename"
        if [[ ! -L "$link_path" || ! "$link_path" -ef "$target_abs_path" ]]; then
            mkdir -p $wants_dir
            ln -sf "../$service_filename" "$link_path"
            patched=1
        fi
    }
    # 打包还原
    if [[  $patched -eq 1 ]];then
        find . -path "./initrd" -prune -o -print |cpio -co --quiet --renumber-inodes --ignore-devno|gzip >"$tmpDir/initrd"
        mv "$tmpDir/initrd" "$initrd_file"
    fi
    rm -rf $tmpDir
    cd $olddir
}
# 在所有initrd中插入脚本重启完成系统打包,生成升级包和安装包
patch_initrds(){
    local dir="${kernel_path%/*}"
    for file in "$dir"/*.img; do
        if [ ! -e "$file" ]; then
            continue
        fi
        if [ ! -f "$file" ] || [ -L "$file" ]; then
            continue
        fi
        patch_initrd "$file"
    done
}
# 检查需要的工具是否存在
check_tool
# 读取历史配置
load_config
# 获取内核路径
kernelPath_get
# 准备aos系统
prepare_aos
# 设置BcoreOS标记
set_BcoreOSTag
# 设置输出名字
set_output_name
outputAOS="$aosDir/$outputName-${aosVersion}_AOS.img.gz"
outputBcoreOS="$aosDir/$outputName-${aosVersion}_BcoreOS.upt"
if [[ -a "$outputAOS" ]];then rm -rf "$outputAOS";fi
if [[ -a "$outputBcoreOS" ]];then rm -rf "$outputBcoreOS";fi
echo -n "Configuring system... "
(
    PPID_OF_MAIN=$$
    SECONDS=0
    while true; do
        if (( SECONDS % 10 == 5 )); then
            if ! kill -0 $PPID_OF_MAIN 2>/dev/null; then
                exit 0
            fi
        fi
        display_seconds=$(( SECONDS / 10 ))
        echo -e "\rConfiguring system... ${display_seconds}s\c"
        sleep 0.1
        SECONDS=$((SECONDS + 1))
    done
) &
TIMER_PID=$!
# 准备打包工具
prepare_ptool
# 在所有initrd中插入脚本重启完成系统打包,生成升级包和安装包
patch_initrds
# 删除
rm -rf "$aosDir/ptool"
kill "$TIMER_PID" 2>/dev/null
wait "$TIMER_PID" 2>/dev/null
echo -e "\rConfiguring system... done."

cat > "$aosDir/config" <<EOF
[config]
aosImg=$aosImg
BcoreOSTag=$BcoreOSTag
outputName=$outputName
aosVersion=$aosVersion
EOF
sync
echo "Config is:
    aosImg    : $aosImg
    BcoreOSTag: $BcoreOSTag
    outputName: $outputName-$aosVersion
"
echo "System will reboot to build BcoreOS. After the reboot is complete, the following files will be generated:"
echo "  - Pre-installation service package: $outputAOS"
echo "  - All-in-one Update package       : $outputBcoreOS"

for i in {18..1}; do
    current_sec=$(( (i + 1) / 2 ))
    echo -ne "\rPress 'n' to cancel (${current_sec}s) "
    read -s -n 1 -t 0.5 char
    status=$?
    if [[ "${char,}" == "n" ]]; then
        echo -e "\nReboot canceled."
        exit 0
    fi
    if [[ -z "$char" && $status -eq 0 ]]; then
        break
    fi
done
echo -e "\nRebooting now..."
reboot

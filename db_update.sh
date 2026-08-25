#!/bin/sh
# ==============================================================================
# 更新数据
# ==============================================================================
thisDir=$(cd "$(dirname "$0")" && pwd)
BcoreOS_build="$thisDir/BcoreOS_build.sh"
# 原始文件列表
fileList=()
# 已定义的文件信息
fileinfo=()
prepare_fileList(){
    # 1. 局部临时数组，存放未排序的真实文件
    local rawList=()
   
    for file in "$thisDir"/*.img.gz; do
        if [ -f "$file" ] && [ ! -L "$file" ]; then
            rawList+=("$file")
        fi
    done
    # 如果没有找到任何文件，直接退出
    if [ ${#rawList[@]} -eq 0 ]; then
        return
    fi
    # 3. 通过 sort -Vr 实现：按版本/数值自然排序，并【降序】排列
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            fileList+=("$line")
        fi
    done < <(printf '%s\n' "${rawList[@]}" | sort -Vr)
}

# 删除指向fileinfo的所有软连接
remove_links_by_fileList(){
    # 如果 fileList 为空，则无需处理
    if [ ${#fileList[@]} -eq 0 ]; then
        return
    fi
    # 遍历当前目录下的所有文件/链接
    for link in "$thisDir"/*; do
        # 确保当前处理的是软链接
        if [ -L "$link" ]; then
            if [[ ! -e "$link" ]];then
                rm "$link"
            else
                # 遍历 fileList 数组，检查是否有匹配的物理文件
                for item in "${fileList[@]}"; do
                    # -ef 会自动穿透软链接，直接比对底层物理文件是否是同一个
                    if [ "$link" -ef "$item" ]; then
                        rm "$link"
                        break # 匹配成功并删除后，跳出当前 item 循环，继续检查下一个链接
                    fi
                done
            fi
        fi
    done
}

prepare_fileinfo(){
    unique_ledger=" "
    found_function=0
    found_array=0
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        # 1. 💡 用 Bash 原生语法去掉行尾的 Windows \r 换行符（替代 tr -d '\r'）
        line="${raw_line%$'\r'}"
    
        # 2. 第一步：寻找 prepare_aos 函数
        if [ $found_function -eq 0 ]; then
            if [[ "$line" == *"prepare_aos"* ]]; then
                found_function=1
            fi
            continue
        fi
    
        # 3. 第二步：在函数内部寻找 imgs=( 数组
        if [ $found_array -eq 0 ]; then
            if [[ "$line" == *"imgs=("* ]]; then
                found_array=1
            fi
            continue
        fi
    
        # 4. 第三步：精准判断数组结束行（有右括号但绝对没有双引号）
        if [[ "$line" == *")"* ]] && [[ "$line" != *'"'* ]]; then
            break
        fi
    
        # 5. 第四步：处理数据行（必须包含双引号）
        if [[ "$line" == *'"'* ]]; then
            clean_row="${line//\"/}"
        
            # 使用位置参数自动切分，无视行首任意多个缩进空格
            set -- $clean_row
            first_col="$1"  # 第一个元素必定是 32 位 Hash
         
            [ -z "$first_col" ] && continue
        
            # 用 $* 将切分后的各列用单空格重新拼接，自动消除了多余的缩进
            clean_item="$*"
        
            # 6. 万能字符串账本去重
            case "$unique_ledger" in
                *" $first_col "*) 
                    continue 
                    ;;
                *)
                    unique_ledger="$unique_ledger$first_col "
                    fileinfo+=("$clean_item")
                   ;;
            esac
        fi
    done < "$BcoreOS_build"
}
replace_fileinfo(){
    # 接收传入的新字符串
    local new_content="$1"

    local temp_file=""
    
    # ================= 动态自增探测临时文件名 =================
    local suffix_num=1
    while true; do
        temp_file="${BcoreOS_build}.tmp${suffix_num}"
        # [[ ! -e ... ]] 确保该文件在物理上绝对不存在
        if [[ ! -e "$temp_file" ]]; then
            break
        fi
        ((suffix_num++))
    done
    # =========================================================
    
    local found_function=0
    local found_array=0
    local is_skipping=0

    # 创建并初始化该空闲的临时文件
    : > "$temp_file"

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        local line="${raw_line%$'\r'}"
    
        # 1. 寻找 prepare_aos 函数
        if [ $found_function -eq 0 ]; then
            if [[ "$line" == *"prepare_aos"* ]]; then
                found_function=1
            fi
            echo "$raw_line" >> "$temp_file"
            continue
        fi
    
        # 2. 在函数内部寻找 imgs=( 数组的起点
        if [ $found_array -eq 0 ]; then
            if [[ "$line" == *"imgs=("* ]]; then
                found_array=1
                is_skipping=1  
                
                # 写入数组开头 imgs=(
                echo "$raw_line" >> "$temp_file"
                
                # 核心注入点
                if [ -n "$new_content" ]; then
                    printf '%s' "$new_content" >> "$temp_file"
                fi
            else
                echo "$raw_line" >> "$temp_file"
            fi
            continue
        fi
    
        # 3. 寻找数组结束行
        if [ $is_skipping -eq 1 ]; then
            if [[ "$line" == *")"* ]] && [[ "$line" != *'"'* ]]; then
                is_skipping=0  
                echo "$raw_line" >> "$temp_file" 
            fi
            continue
        fi
    
        # 4. 数组结束之后的其余行
        echo "$raw_line" >> "$temp_file"

    done < "$BcoreOS_build"

    # 5. 原子级覆盖原文件
    chmod 777 "$temp_file"
    mv "$temp_file" "$BcoreOS_build"
}
update_db(){
    local outData=""
    for file in "${fileList[@]}"; do
        local filename="${file##*/}"
        local name="${filename%%-*}"
        local tmp1="${filename#*-}"
        local version="${tmp1%%-*}"
        tmp1="${tmp1#*-}"
        tmp1="${tmp1#*-}"
        local kernelhash="${tmp1%%-*}"
        local oldname=""
        for info in "${fileinfo[@]}"; do
            local kernelhash_old="${info%% *}"
            if [[ $kernelhash = $kernelhash_old ]];then
                oldname="${info#* }"
                oldname="${oldname#* }"
                break
            fi
        done
        local fileMd5=$(debug -E -mf $file | grep -o -E -m 1 '[0-9a-fA-F]{32}')
        if [[ -z "$oldname" ]]; then
            local NL=$'\n'
            outData="$outData        \"$kernelhash $fileMd5 $name-$version\"$NL"
        else
            local head="${oldname%%-*}"
            local tail="${oldname#*[0-9]}"
            while [[ "${tail:0:1}" == [0-9] || "${tail:0:1}" == "." ]]; do
                tail="${tail:1}"
            done
            local NL=$'\n'
            outData="$outData        \"$kernelhash $fileMd5 $head-$version$tail\"$NL"
        fi
        ln -s "$filename" "$thisDir/$name-$fileMd5"
    done
    echo "$outData"
    replace_fileinfo "$outData"
}
prepare_fileList
#printf "%s\n" "${fileList[@]}"
remove_links_by_fileList
prepare_fileinfo
#printf "%s\n" "${fileinfo[@]}"
update_db
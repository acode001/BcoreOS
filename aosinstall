#!/bin/bash
if [[ $(id -u) -ne 0 ]];then
   if [[ -f /sbin/sudo ]] || [[ -f /bin/sudo ]] || [[ -f /usr/sbin/sudo ]] || [[ -f /usr/bin/sudo ]];then
     sudo $0 "$@"
     exit 0
   else
     echo "Require root privileges!!!"
     exit 1
   fi
fi
if [[ "$0" != "/dev/shm/xiaozhiosinstall" ]];then
  if [ ! -f /dev/shm/xiaozhiosinstall ];then
    cp -a $(pwd)/"$0" /dev/shm/xiaozhiosinstall
  fi
  /dev/shm/xiaozhiosinstall "$@"
  exit 0
fi
img=""
imgfromNet=0
if [ $# -lt 1 ];then
  echo "Please select a img,eg. \""$0" ./xiaozhios.img.gz\""
  imgtype="n"
  read -t 5 -p "Try get img from network(e/y/n/x),default y:" the_ok
  if [ $the_ok"x" == "xx" ];then 
    exit 0
  else
    if [ $the_ok"x" == "ex" ];then imgtype="e"
    elif [ $the_ok"x" == "yx" ];then imgtype="y"
    fi
    if [[ ! -f /sbin/wget ]] && [[ ! -f /bin/wget ]] && [[ ! -f /usr/sbin/wget ]] && [[ ! -f /usr/bin/wget ]];then
      if [[ -f /sbin/dnf ]] || [[ -f /bin/dnf ]];then
        killall -9 dnf;dnf install -y wget || exit 1
      elif [[ -f /sbin/apt ]] || [[ -f /bin/apt ]];then
        apt install -y wget || exit 1
      elif [[ -f /usr/sbin/yum ]] || [[ -f /usr/bin/yum ]];then
        yum install -y wget || exit 1
      elif [[ -f /usr/sbin/yzpper ]] || [[ -f /usr/bin/yzpper ]];then
        yzpper install -y wget || exit 1
      else
        echo "Can not install wget!!!"
        exit 1
      fi
    fi
    platform=$(uname -i);
    if [[ $platform == "unknown" ]];then platform=$(uname -m); fi
    if [[ $platform == "x86_64" ]];then
      if [ $imgtype"x" == "ex" ];then img=xiaozhios-5.203.6912-202402251120-vfat-ape-x86-64-vda.img.gz
      elif [ $imgtype"x" == "yx" ];then img=xiaozhios-5.203.6912-202402251115-vfat-ap-x86-64-vda.img.gz
      else img=xiaozhios-5.203.6912-202402251120-vfat-x86-64-vda.img.gz
      fi
    elif [[ $platform == "s390x" ]];then
      img=xiaozhios-5.200.3976-202309112134-ext2-ape-s390x-dasda.img.gz
    else
      echo "Unkown platform!!!"
      exit 1
    fi
    if [[ -f $img ]];then rm -rf $img;fi;
    wget http://mym9.com:16080/files/$img || exit 1
    imgfromNet=1
  fi
else
  img=$1
  imgfromNet=0
fi
if [[ ${img} =~ ^/ ]];then
  img=${img}
else
  img="$(pwd)/${img}"
fi
memsize=$(cat /proc/meminfo |awk /^MemTotal/'{print $2}')
if [[ $memsize"x" == "x" ]];then
  echo "Get memsize failed"
  exit 0
else
  a=$(cat /proc/meminfo |awk /^MemTotal/'{print $3}')
  if [ "$a" == "kB" ];then
    memsize=$(($memsize*1024))
  else
    echo "Get memsize failed:"$a
    exit 0
  fi
fi
disk=""
for i in "/boot" "/";do
  if [[ $disk"t" == "t" ]];then
    a=$(df -k |grep $i$ |awk '{print $1}')
    if [[ "$a" == /dev/* ]];then
      if [[ "$a" == /dev/mapper/* ]];then
        a=${a//--/-}
        key=${a##*/}
        while [[ $key"t" != "t" ]];do
          key=${key:0:$[${#key} - 1 ]}
          disk1=$(pvs|awk '{if($2=="'$key'")printf $1}')
          if [[ $disk1"t" != "t" ]];then
            a=$disk1
            break;
          fi
        done
      fi
      disk=$a
      while [[ ! $disk"x" = "x" ]];do
          if [[ ${disk:0-1:1} =~ ^[0-9]$ ]];then disk=${disk::-1};else break;fi
      done
      if [[ ${disk:0-1:1} = "p" ]] && [[ ${disk:0-2:1} =~ ^[0-9]$ ]];then disk=${disk::-1};fi
    fi
  fi
done
if [[ $disk"t" == "t" ]];then
    echo "Get disk failed"
    exit 0
fi
defaultroute=$(ip route |awk '$1~/^default$/{print $3}')
if [[ $defaultroute"t" == "t" ]];then
  echo "Get default route failed"
  exit 0
fi
ipaddr=$(ip addr |grep `ip route |awk /$defaultroute/'$1~/default$/{print $5}'` |awk '$1~/^inet$/{print $2}')
if [[ $ipaddr"t" == "t" ]];then
  echo "Get ipaddr failed"
  exit 0
fi
echo "Install disk: "$disk
echo "IP:           "$ipaddr
echo "GateWay:      "$defaultroute
if [ $memsize -gt 10998998998 ];then
  echo "Memsize:      "$(($memsize/1024/1024/1024)) "G"
elif [ $memsize -gt 10998998 ];then
  echo "Memsize:      "$(($memsize/1024/1024)) "M"
elif [ $memsize -gt 10998 ];then
  echo "Memsize:      "$(($memsize/1024)) "kB"
else
  echo "Memsize:      "$memsize "B"
fi
if [[ $imgfromNet -eq 0 ]];then
  read  -p "Do you want continue(y/n):" the_ok
  if [ $the_ok"x" != "yx" ];then exit 0;fi
fi
echo "Start install ..."
hasError=0
cp_depends() {
  if [ $# -lt 2 ];then
    echo "cp_depends,parameter error,count=$#"
    exit 1
  fi
  local src=$1;
  local dstDir=$2;
  for i in $(ldd "$src" | awk '{if($3)print $3}'); do
    if [[ ${i:0:1} = "(" ]] ;then continue;fi
    local dst="$dstDir/${i##*/}"
    if [ ! -a $dst ];then
      if [ -L $i ];then cp -Lp $i $dst;
      else cp -a $i $dst;fi
      if [ $? -ne 0 ]; then
        echo "cp $i failed"
        hasError=1;
      fi
    fi
    cp_depends $dst $dstDir
  done
}
freeSize_get() {
  local freeSize=0
  local freeSize_line=$(cat /proc/meminfo | grep "MemFree")
  local freeSize_value=$(echo "$freeSize_line" | awk '{print $2}')
  local freeSize_unit=$(echo "$freeSize_line" | awk '{print $3}')
  case "$freeSize_unit" in
    "kB")
      freeSize=$(($freeSize_value * 1))
      ;;
    "MB")
      freeSize=$(($freeSize_value * 1024))
      ;;
    "GB")
      freeSize=$(($freeSize_value * 1024 * 1024))
      ;;
    *)
      echo "Unkown data: $freeSize_line"
      exit 1
      ;;
  esac
  echo $freeSize 
}

if [ ! -d /xiaozhi ];then
  mkdir /xiaozhi
## cp command to /dev/shm/cmd
  dstDir="/dev/shm/cmd"
  mkdir $dstDir
  for i in $(echo -e "gzip\ndd\nsync\nsleep\nreboot");do
    srcDir="";
    if [ -a /usr/bin/$i ];then srcDir="/usr/bin";
    elif [ -a /usr/sbin/$i ];then srcDir="/usr/sbin";
    elif [ -a /bin/$i ];then srcDir="/bin";
    elif [ -a /sbin/$i ];then srcDir="/sbin";
    else echo "Can not find $i";exit 1;fi
    if [ -L $srcDir/$i ];then cp -Lp $srcDir/$i $dstDir/$i;
    else cp -a $srcDir/$i $dstDir/$i;fi
    cp_depends $dstDir/$i $dstDir 
  done
## resize /dev/shm
  echo 3 >/proc/sys/vm/drop_caches   
  freeSize=`freeSize_get`
  freeSize=$(($freeSize - 1 * 1024 ))
  shmSize=$(df -k |awk '{if($6 ~ "^/dev/shm$")print $2}')
  if [[ $shmSize -lt $freeSize ]];then
    mount -o remount,size=$(($freeSize / 1024))M /dev/shm
  fi
## mkswap
if [ ! -d / ];then
  rootSize=$(df -k |awk '{if($6 ~ "^/$")print $3}')
  shmSize=$(df -k |awk '{if($6 ~ "^/dev/shm$")print $2}')
  if [[ ! -f /xiaozhi/swap ]] && [[ $shmSize -lt $rootSize ]];then
    dd if=/dev/zero of=/xiaozhi/swap bs=1024000 count=$((($rootSize-$shmSize)/1024+10)) >/dev/null 2>&1
    chmod 0600 /xiaozhi/swap
    mkswap /xiaozhi/swap
    swapon /xiaozhi/swap
    mount -o remount,size=$(($rootSize / 1024 + 10))M /dev/shm
  fi
fi
  if [ ! -f /dev/shm/xiaozhios.img.gz ];then 
    cp -an $img /dev/shm/xiaozhios.img.gz
  fi
  if [[ "x"$(ls -l /dev/shm/xiaozhios.img.gz |awk '{print $5}') = "x"$(ls -l $img |awk '{print $5}') ]];then img="/dev/shm/xiaozhios.img.gz";fi
  gzip -cd $img >/xiaozhi/xiaozhios.img
if [ ! -d / ];then
  for i in $(echo -e "/lib\n/usr\n/lib64\n/bin\n/sbin\n/etc\n/var");do
    if [ ! -L $i ] && [ -d $i ];then
      if [ $hasError -eq 0 ];then
        cp -an $i /dev/shm$i >/dev/null 2>&1
        shmFreeSize=`df -k |awk '$6~/^\/dev\/shm$/{print $4}'`
        if [ "x$shmFreeSize" == "x" ];then
          shmFreeSize=`df -k |awk '$1~/^tmpfs$/ && $6~/^\/etc$/{print $4}'`
        fi
        if [ "x$shmFreeSize" == "x" ];then
          shmFreeSize=`df -k |awk '$1~/^tmpfs$/ && $6~/^\/usr$/{print $4}'`
        fi
        if [ $shmFreeSize -gt 10240 ];then  mount -o bind /dev/shm$i $i;
        else hasError=1;fi        
      fi
      if [ $hasError -ne 0 ];then
        echo "Not enough space to retain the original system,dir:\"$i\"."
        #break; 
        cp -an $i /xiaozhi$i
        mount -o bind /xiaozhi$i $i
        sync
      fi
    fi
  done
fi
else
  if [ ! -f /dev/shm/xiaozhios.img.gz ];then 
    cp -an $img /dev/shm/xiaozhios.img.gz
  fi
  if [[ "x"$(ls -l /dev/shm/xiaozhios.img.gz |awk '{print $5}') = "x"$(ls -l $img |awk '{print $5}') ]];then img="/dev/shm/xiaozhios.img.gz";fi
  gzip -cd $img >/xiaozhi/xiaozhios.img
  if [ $hasError -eq 0 ];then
    shmFreeSize=`df -k |awk '$6~/^\/dev\/shm$/{print $4}'`
    if [ $shmFreeSize -lt 10240 ];then hasError=1; fi
  fi
fi
if [ $hasError -ne 0 ];then
  if [[ $imgfromNet -eq 0 ]];then
    read -p "Has some error,do you want continue(y/n):" the_ok
    if [ $the_ok"x" != "yx" ];then 
      exit 0
    fi
  else
    read -t 5 -p "Has some error,do you want continue(y/n),default y:" the_ok
    if [ $the_ok"x" == "nx" ];then 
      exit 0
    fi
  fi
fi
{
  disksize=$(fdisk $disk -l |grep "$disk" |awk /^Disk/'{print $5}')
  if [ $disksize"x" == "x" ];then
    disksize=$(fdisk $disk -l |grep "$disk" |awk /^磁盘/'{print $4}')
  fi
  xiaozhiosinit=""
  if [ $hasError -eq 0 ];then xiaozhiosinit="/dev/shm/xiaozhiosinit"
  else xiaozhiosinit="/xiaozhi/xiaozhiosinit"; fi
  str="[network]\n"
  i=1
  for ip in $ipaddr; do
    str="${str}ip$i=$ip\n"
    ((i++))
  done
  echo -e "${str}gateway=$defaultroute\n" > "$xiaozhiosinit"
  xiaozhiosinitsize=$(ls -l $xiaozhiosinit | awk '{print $5}')
  count=$((($xiaozhiosinitsize+487) / 488))
  skip=0;
  for((i=0;i<count;i++));do
    a=$(printf "%05d" $i)
    echo -e "$a.xiaozhi.fslib.org\n" >$xiaozhiosinit$a
    thesize=$(($xiaozhiosinitsize-$skip))
    if [ $thesize -ge 488 ];then
      thesize=488
      dd if=$xiaozhiosinit of=$xiaozhiosinit$a conv=notrunc bs=1 skip=$skip seek=24 count=$thesize &>/dev/null
      skip=$(($skip+$thesize))
    else
      dd if=$xiaozhiosinit of=$xiaozhiosinit$a conv=notrunc bs=1 skip=$skip seek=24 count=$thesize &>/dev/null
      skip=$(($skip+$thesize))
      dd if=/dev/zero of=$xiaozhiosinit$a conv=notrunc bs=1 seek=$((24+$thesize)) count=$((488-$thesize)) &>/dev/null
    fi
    dd if=$xiaozhiosinit$a of=$disk conv=notrunc bs=1 seek=$(($disksize-($count-$i)*512)) count=512 &>/dev/null
  done
}
sync
imgsize=$(ls -l /xiaozhi/xiaozhios.img | awk '{print $5}')
memsize=$(($memsize + $imgsize))
b='#'
echo 3 >/proc/sys/vm/drop_caches  
freeSize=`freeSize_get`
shmSize=$(df -k |awk '{if($6 ~ "^/dev/shm$")print $4}')
if [ $freeSize -gt $shmSize ];then freeSize=$shmSize;fi
freeSize=$(($freeSize/1024 - 1))  
shmSize=$(df -k |awk '{if($6 ~ "^/dev/shm$")print $3}')
memsize=$(($memsize - $shmSize * 1024 - $freeSize * 1024 *1024 ))
trap '' SIGHUP
export LD_LIBRARY_PATH=/dev/shm/cmd:$LD_LIBRARY_PATH
export PATH="/dev/shm/cmd"
for((i=0;i<=memsize;));do    
    a=$(($i * 100 / $memsize))
    printf "progress:[%-100s]%d%%\r" $b $a    
    i=$(($i + $imgsize))
    gzip -cd $img >$disk
    a=$(($i * 100 / $memsize))
    if [ $a -gt 100 ];then
      a=100
    fi
    while [ ${#b} -lt $a ];do
      b=#$b
    done
    sync
done
printf "progress:[%-100s]%d%%\r" $b 100
echo ""
echo "Install successfully,reboot ..."
sleep 3
## full shm
if [ $freeSize -gt 1 ];then
  dd if=/dev/zero of=/dev/shm/__f bs=1024000 count=$freeSize >/dev/null
fi
echo 1 > /proc/sys/kernel/sysrq
echo b > /proc/sysrq-trigger
sleep 3
reboot -f

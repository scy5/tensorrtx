#!/bin/bash

# 用法:
#   ./trtx_yolov8m_pt2engine.sh [-fp32|-fp16] [-inputsize=N] <pt_path> <class_num> [target]
# 示例:
#   ./trtx_yolov8m_pt2engine.sh -fp16 -inputsize=320 a.pt 80 detect

precision_flag=""
input_size=""

# 解析参数：分离可选 flag 和位置参数
positional_args=()
for arg in "$@"; do
    case "$arg" in
        -fp32|-fp16)
            precision_flag="${arg#-}"   # 去掉 "-"，得到 fp32 或 fp16
            ;;
        -inputsize=*)
            input_size="${arg#*=}"
            ;;
        *)
            positional_args+=("$arg")
            ;;
    esac
done

# 位置参数校验
if [ ${#positional_args[@]} -lt 2 ] || [ ${#positional_args[@]} -gt 3 ]; then
    echo "Usage: $0 [-fp32|-fp16] [-inputsize=N] <pt_path> <class_num> [target]"
    exit 1
fi

# 获取脚本所在的绝对路径
script_path=$(cd "$(dirname "$0")" && pwd)
echo "脚本所在路径: ${script_path}"
trtx_path=${script_path}/..

pt_path=$(realpath "${positional_args[0]}")
class_num="${positional_args[1]}"
if [ ${#positional_args[@]} -eq 3 ]; then
	target="${positional_args[2]}"
else
	target="detect"
fi

# 检查 pt 文件是否存在
if [ -f "$pt_path" ]; then
    echo "-- input pt file path: $pt_path"
else
    echo "-- failed to find $pt_path"
    exit 1
fi

# 检查 class_num 是否是数字
if [[ "$class_num" =~ ^[0-9]+$ ]]; then
    echo "-- input class num: $class_num"
else
    echo "-- invalid class num: $class_num"
    exit 1
fi

# 检查 input_size 是否是数字
if [ -n "$input_size" ]; then
    if [[ "$input_size" =~ ^[0-9]+$ ]]; then
        echo "-- input size: $input_size"
    else
        echo "-- invalid input size: $input_size"
        exit 1
    fi
fi

pt_name=$(basename "$pt_path" .pt)

function modify_config() {
	cd ${trtx_path}

	# 精度宏设置
	if [ "$precision_flag" = "fp32" ]; then
		echo "-- switching to FP32 precision"
		sed -i "s/#define USE_FP16/\/\/#define USE_FP16/g" yolov8/include/config.h
		sed -i "s/\/\/#define USE_FP32/#define USE_FP32/g" yolov8/include/config.h
	elif [ "$precision_flag" = "fp16" ]; then
		echo "-- switching to FP16 precision"
		sed -i "s/#define USE_FP32/\/\/#define USE_FP32/g" yolov8/include/config.h
		sed -i "s/^#define USE_FP16/\/\/#define USE_FP16/g" yolov8/include/config.h
		sed -i "s/\/\/#define USE_FP16/#define USE_FP16/g" yolov8/include/config.h
	fi

	# 输入尺寸设置
	if [ -n "$input_size" ]; then
		echo "-- setting input size to ${input_size}x${input_size}"
		sed -i -E "s/kInputH = [0-9]+;/kInputH = $input_size;/g" yolov8/include/config.h
		sed -i -E "s/kInputW = [0-9]+;/kInputW = $input_size;/g" yolov8/include/config.h
	fi

	# kNumClass 设置
	sed -i -E "s/kNumClass = [0-9]+;/kNumClass = $class_num;/g" yolov8/include/config.h
}

function generate_wts() {
	cd ${trtx_path}
	mkdir -p yolov8/build
	cd yolov8/build
	cmake ..
	make

	cd ../..

	if [ "$target" = "cls" ]; then
		echo "-- python3 yolov8/gen_wts.py -w $pt_path -o yolov8/build/$pt_name.wts -t cls"
		python3 yolov8/gen_wts.py -w $pt_path -o yolov8/build/$pt_name.wts -t cls
	elif [ "$target" = "seg" ]; then
		echo "-- python3 yolov8/gen_wts.py -w $pt_path -o yolov8/build/$pt_name.wts -t seg"
		python3 yolov8/gen_wts.py -w $pt_path -o yolov8/build/$pt_name.wts -t seg
	else
		echo "-- python3 yolov8/gen_wts.py -w $pt_path -o yolov8/build/$pt_name.wts -t detect"
		python3 yolov8/gen_wts.py -w $pt_path -o yolov8/build/$pt_name.wts -t detect
	fi
}

function generate_engine() {
	cd ${trtx_path}
	out_path="out"
	echo "-- mkdir $out_path"
	mkdir -p "$out_path"

	# 获取显卡型号并提取 "NVIDIA RTX" 后面的部分
	gpu_model=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader,nounits | head -n 1 | sed -n "s/.*NVIDIA RTX //p" | sed "s/ //g")
	# 获取显卡驱动版本并提取主版本号
	gpu_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -n 1 | cut -d '.' -f 1)

	engine_name="${pt_name}_${gpu_model}_nv${gpu_driver}.engine"

	if [ "$target" = "cls" ]; then
		echo "-- ./yolov8/build/yolov8_cls -s yolov8/build/$pt_name.wts $engine_name m $class_num"
		./yolov8/build/yolov8_cls -s yolov8/build/$pt_name.wts ${out_path}/$engine_name m $class_num
	elif [ "$target" = "seg" ]; then
		echo "-- ./yolov8/build/yolov8_seg -s yolov8/build/$pt_name.wts $engine_name m $class_num"
		./yolov8/build/yolov8_seg -s yolov8/build/$pt_name.wts ${out_path}/$engine_name m $class_num
	else
		echo "-- ./yolov8/build/yolov8_det -s yolov8/build/$pt_name.wts $engine_name m $class_num"
		./yolov8/build/yolov8_det -s yolov8/build/$pt_name.wts ${out_path}/$engine_name m $class_num
	fi

	if [ $? -ne 0 ]; then
		echo "-- failed to generate ${out_path}/$engine_name"
		exit 1
	fi

	echo "-- ${out_path}/$engine_name is generated"
}

modify_config
generate_wts
generate_engine

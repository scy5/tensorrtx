# .trtx_yolov8m_pt2engine.sh a.pt 5

if [ $# -ne 2 ]; then
    echo "Usage: .trtx_yolov8m_pt2engine.sh a.pt 5 <pt_path> <class_num>"
    exit 1
fi

pt_path=$1
class_num=$2

# 检查第一个参数是否是存在的文件
if [ -f "$pt_path" ]; then
    echo "-- input pt file path:$pt_path"
else
    echo "-- failed to find $pt_path"
    exit 1
fi

# 检查第二个参数是否是数字
if [[ "$class_num" =~ ^[0-9]+$ ]]; then
    echo "-- input class num: $class_num"
else
    echo "-- invalid class num: $class_num"
    exit 1
fi

pt_name=$(basename "$pt_path" .pt)

function modify_code() {
	sed -i "s/YoloLayer_TRT/Yolov8Layer_TRT/g" yolov8/src/block.cpp yolov8/plugin/yololayer.cu
	sed -i -E "s/kNumClass = [0-9]+;/kNumClass = $class_num;/g" yolov8/include/config.h
	sed -i "s/#define USE_FP16//g" yolov8/include/config.h
	sed -i "s/\/\/#define USE_FP32/#define USE_FP32/g" yolov8/include/config.h
}

function generate_wts() {
	mkdir yolov8/build
	cd yolov8/build
	cmake ..
	make

	cd ../..
	echo "-- python3 yolov8/gen_wts.py -w $pt_path -o yolov8/build/$pt_name.wts -t detect"
	python3 yolov8/gen_wts.py -w $pt_path -o yolov8/build/$pt_name.wts -t detect
}

function generate_engine() {
	out_path="out"
	echo "-- mkdir $out_path"
	mkdir "$out_path"

	# 获取显卡型号并提取“NVIDIA RTX”后面的部分
	gpu_model=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader,nounits | head -n 1 | sed -n "s/.*NVIDIA RTX //p" | sed -n "s/ //p")
	# 获取显卡驱动版本并提取主版本号（例如“550”）
	gpu_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -n 1 | cut -d '.' -f 1)

	# echo "$pt_path" | sed -n "s/abc.pt/_$gpu_model_$gpu_driver\.engine/g"
	engine_name="${pt_name}_${gpu_model}_nv${gpu_driver}.engine"
	
	echo "-- ./yolov8/build/yolov8_det -s yolov8/build/$pt_name.wts $engine_name m"
	./yolov8/build/yolov8_det -s yolov8/build/$pt_name.wts ${out_path}/$engine_name m
	
	if [ $? -ne 0 ]; then
		echo "-- failed to generate ${out_path}/$engine_name"
		exit 1
	fi
	
	echo "-- ${out_path}/$engine_name is generated"
}

modify_code
generate_wts
generate_engine

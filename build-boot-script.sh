#!/bin/bash
set -ex
set -o pipefail

#######################################
# Usage 
#######################################
usage() {
    cat <<EOF
Usage:
  $0 -g <linux-git-url> -b <branch> -i <distro img> -f <fs type> -c <avocado-config> [-l <label>]

Required:
  -g <linux-git-url>    Linux URL to build,boot and test
  -b <branch>  		Branch in the repo
  -i <distro img>	Distro image to boot into
  -f <filesystem>	Filesystem to test
  -c <avocado-config>	avocado config file for the FS

Optional:
  -l <label>		label to identify the run
  -h          		Show this help

Example:
   $0 -g https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
       -b master -i ubuntu20.04-cloudimg-ppc64el.qcow2"
       -f ext4 -c ci.yaml -l test-run"
EOF
    exit 1
}

GIT_URL=""
BRANCH=""
IMG=""
FS=""
CFG=""
LABEL=""

while getopts ":g:b:i:f:c:l:h" opt; do
    case "$opt" in
        g) GIT_URL="$OPTARG" ;;
        b) BRANCH="$OPTARG" ;;
        i) IMG="$OPTARG" ;;
        f) FS="$OPTARG" ;;
        c) CFG="$OPTARG" ;;
        l) LABEL="$OPTARG" ;;
        h) usage ;;
        :)
            echo "Option -$OPTARG requires an argument"
            usage
            ;;
        \?)
            echo "Invalid option -$OPTARG"
            usage
            ;;
    esac
done

#######################################
# Validate required args
#######################################
[[ -z "$GIT_URL" ]] && { echo "Missing -g"; usage; }
[[ -z "$BRANCH" ]] && { echo "Missing -b"; usage; }
[[ -z "$IMG" ]] && { echo "Missing -i"; usage; }
[[ -z "$FS" ]] && { echo "Missing -f"; usage; }
[[ -z "$CFG" ]] && { echo "Missing -f"; usage; }
[[ -z "$LABEL" ]] && LABEL="unlabelled"


###############
# Start - configure globals and fetch prerequisite scripts
###############
root_dir="$PWD/output"
jenkins_workspace_dir="$PWD/output/run"
linux_dir="${jenkins_workspace_dir}/linux"
ci_scripts_dir="$root_dir/ci-scripts"

if [ ! -d ${ci_scripts_dir} ] || [ -z "$(ls -A ${ci_scripts_dir})" ]; then
    git clone --depth=1 https://github.com/OjaswinM/ci-scripts.git ${ci_scripts_dir}
fi

#############
# Clone Linux
#############
# TODO: Eventually we need to clone into a unique folder named after the commit hash
if [[ ! -d $linux_dir ]]; then
    git clone --depth=1 $GIT_URL -b $BRANCH ${linux_dir}
fi

#############
# build phase
#############
build_dir="$ci_scripts_dir/build"
kernel_output_dir="${jenkins_workspace_dir}/build"
defconfig="ppc64le_guest_defconfig"

mkdir -p $kernel_output_dir
export CI_OUTPUT="$kernel_output_dir"
# this is the toolchain used to build the kernel
build_make_cmd="make kernel@ppc64le@fedora SRC=${linux_dir} JFACTOR=$(nproc) DEFCONFIG=${defconfig}"

pushd $build_dir
$build_make_cmd
popd

#############
# root disk download
#############
image_name=$IMG
disk_make_dir="$ci_scripts_dir/root-disks"
disk_make_cmd="make $image_name"

pushd $disk_make_dir
./install-deps.sh
make cloud-init-user-data.img
$disk_make_cmd
popd

#############
# boot qemu phase
#############
boot_script_dir=$ci_scripts_dir/scripts/boot
test_output_dir="$jenkins_workspace_dir/output"

mkdir -p $test_output_dir

# 3rd argument is of form "fs:config, this is because handling spaces was becoming an issue"
boot_script="${boot_script_dir}/qemu-pseries --accel kvm --cpu POWER8 --cloud-image ${image_name} --test-name avocado --pexpect-timeout 0 --test-output-dir $test_output_dir --test-args $FS:$CFG --mem-size 8G"
KBUILD_OUTPUT=${kernel_output_dir}/latest-kernel ${boot_script}
echo Output $?

#########
# convert logs to format of dashboard
#########
xfstests_scripts_dir="$PWD/xfstests-scripts"
avocado_convert_script="$xfstests_scripts_dir/convert.py"
xml_path="$test_output_dir/results/result.xml"
xfstests_results_path="$test_output_dir/results/."
logs_op_path="$test_output_dir/output-logs/."
json_op_path="$test_output_dir/dashboard_result.json"

# This is the path where we will push it to remote machine via ssh. Make sure that 
# this dir is created and remote ssh user has permission to create files here.
log_prefix="/var/log/ci-dashboard"

fs=$FS
config=$CFG
testtype="avocado-xfstest-$fs"
subtype="${config//./-}" # replace . with -
label_arg=""
if [[ -n $LABEL ]]
then
	label_arg="--label $LABEL"
fi

if [[ -f "$xml_path" && -d "$xfstests_results_path" ]]
then
	python3 $xfstests_scripts_dir/convert.py $xml_path $xfstests_results_path $logs_op_path $log_prefix \
		--output_json $json_op_path \
		--type $testtype \
		--subtype $subtype \
		$label_arg | tee $test_output_dir/.convert.log
	run_id=$(cat $test_output_dir/.convert.log | tail -n 1 |  awk '{print $3}')

	$xfstests_scripts_dir/push_logs.sh $run_id $logs_op_path $json_op_path
else
	echo "Either $xml_path or $xfstests_results_path doesn't exist. Something went wrong."
fi

pushd $test_output_dir
rm -f ../logs.zip
zip -qr ../logs.zip avocado-logs.zip results
popd

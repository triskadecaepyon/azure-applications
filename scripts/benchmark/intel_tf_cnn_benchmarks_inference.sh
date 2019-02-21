#!/bin/bash
#
# Copyright (c) 2019 Intel Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

####### USAGE #########
# bash intel_tf_cnn_benchmarks.sh <option> 
# 
# By default, this runs only InceptionV3 at batch size 128. Pass "all" in the <option> 
# position to run all networks and batch sizes in the benchmarking suite.
# 
# This script runs inference with TensorFlow's CNN Benchmarks and summarizes throughput
# increases when using Intel optimized TensorFlow.
# Note: you may need to edit benchmarks/scripts/tf_cnn_benchmarks/datasets.py to 
# import _pickle instead of Cpickle

# Set number of batches
num_batches=( 30 )
num_warmup_batches=20
num_inter_threads=2
kmp_blocktime=0

# Assign num_cores to the number of physical cores on your machine
cores_per_socket=`lscpu | grep "Core(s) per socket" | cut -d':' -f2 | xargs`
num_sockets=`lscpu | grep "Socket(s)" | cut -d':' -f2 | xargs`
num_cores=$((cores_per_socket * num_sockets))

# Check if "all" option was passed, set networks and batch sizes accordingly
option=$1
if [ -z $option ]
then
  networks=( inception3 )
  batch_sizes=( 128 )
else
  networks=( inception3 resnet50 resnet152 vgg16 )
  batch_sizes=( 32 64 128 )
fi

# Clone benchmark scripts
git clone -b cnn_tf_v1.12_compatible  https://github.com/tensorflow/benchmarks.git
cd benchmarks/scripts/tf_cnn_benchmarks
rm *.log # remove logs from any previous benchmark runs

## Run benchmark scripts in the default environment
for network in "${networks[@]}" ; do
  for bs in "${batch_sizes[@]}"; do
    echo -e "\n\n #### Starting $network and batch size = $bs ####\n\n"

    time python tf_cnn_benchmarks.py --device=cpu --mkl=False --data_format=NHWC \
    --num_warmup_batches=$num_warmup_batches --batch_size=$bs \
    --num_batches=$num_batches --model=$network  \
    --num_intra_threads=$num_cores --num_inter_threads=$num_inter_threads \
    --forward_only=True \
    2>&1 | tee net_"$network"_bs_"$bs"_default_inf.log

  done
done

## Run benchmark scripts in the Intel Optimized environment
source activate intel_tensorflow_p36

for network in "${networks[@]}" ; do
  for bs in "${batch_sizes[@]}"; do
    echo -e "\n\n #### Starting $network and batch size = $bs ####\n\n"

    time python tf_cnn_benchmarks.py --device=cpu --mkl=True --data_format=NCHW \
    --kmp_affinity='granularity=fine,noverbose,compact,1,0' \
    --kmp_blocktime=$kmp_blocktime --kmp_settings=1 \
    --num_warmup_batches=$num_warmup_batches --batch_size=$bs \
    --num_batches=$num_batches --model=$network  \
    --num_intra_threads=$num_cores --num_inter_threads=$num_inter_threads \
    --forward_only=True \
    2>&1 | tee net_"$network"_bs_"$bs"_optimized_inf.log

  done
done

source deactivate

## Print a summary of training throughputs and relative speedups across all networks/batch sizes

speedup_track=0
runs=0

# Set headers
echo $'\n\n\n\n'
echo "######### Executive Summary #########"
echo $'\n'
echo "Environment |  Network   | Batch Size | Images/Second"
echo "--------------------------------------------------------"
for network in "${networks[@]}" ; do
  for bs in "${batch_sizes[@]}"; do
    default_fps=$(grep  "total images/sec:"  net_"$network"_bs_"$bs"_default_inf.log | cut -d ":" -f2 | xargs)
    optimized_fps=$(grep  "total images/sec:"  net_"$network"_bs_"$bs"_optimized_inf.log | cut -d ":" -f2 | xargs)
    echo "Default     | $network |     $bs     | $default_fps"
    echo "Optimized   | $network |     $bs     | $optimized_fps"
    speedup=$((${optimized_fps%.*}/${default_fps%.*}))
    speedup_track=$((speedup_track + speedup))
    runs=$((runs+1))
  done
    echo -e "\n"
done

echo "#############################################"
echo "Average Intel Optimized speedup = $(($speedup_track / $runs))X" 
echo "#############################################"
echo $'\n\n'


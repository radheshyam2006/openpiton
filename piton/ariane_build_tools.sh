#!/bin/bash
# Copyright 2018 ETH Zurich and University of Bologna.
# Copyright and related rights are licensed under the Solderpad Hardware
# License, Version 0.51 (the "License"); you may not use this file except in
# compliance with the License.  You may obtain a copy of the License at
# http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
# or agreed to in writing, software, hardware and materials distributed under
# this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, either express or implied. See the License for the
# specific language governing permissions and limitations under the License.
#
# Author: Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
# Date: 26.11.2018
# Description: This script builds the RISCV toolchain, benchmarks, assembly tests
# the RISCV FESVR and the RISCV Torture framework for OpenPiton+Ariane configurations.
# Please source the ariane_setup.sh first.
#
#
# Make sure you have the following packages installed:
#
# sudo apt install \
#          gcc \
#          g++ \
#          gperf \
#          autoconf \
#          automake \
#          autotools-dev \
#          libmpc-dev \
#          libmpfr-dev \
#          libgmp-dev \
#          gawk \
#          build-essential \
#          bison \
#          flex \
#          texinfo \
#          python3-pexpect \
#          libusb-1.0-0-dev \
#          default-jdk \
#          zlib1g-dev \
#          valgrind \
#          csh \
#          gcc-riscv64-unknown-elf \
#          picolibc-riscv64-unknown-elf \
#          verilator \
#          device-tree-compiler


echo
echo "----------------------------------------------------------------------"
echo "building RISCV toolchain and tests (if not existing)"
echo "----------------------------------------------------------------------"
echo

# Verify required tools are installed
for tool in riscv64-unknown-elf-gcc verilator dtc autoconf; do
    if ! command -v $tool >/dev/null 2>&1; then
        echo "ERROR: Required tool '$tool' not found in PATH."
        case $tool in
            riscv64-unknown-elf-gcc)
                echo "Install: sudo apt install gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf"
                ;;
            dtc)
                echo "Install: sudo apt install device-tree-compiler"
                ;;
            *)
                echo "Install: sudo apt install $tool"
                ;;
        esac
        exit 1
    fi
done

if [[ "${RISCV}" == "" ]]
then
    echo "Please source ariane_setup.sh first, while being in the root folder."
else

  git submodule update --init --recursive piton/design/chip/tile/ariane

  # parallel compilation
  export NUM_JOBS=4

  cd piton/design/chip/tile/ariane/

  # Create temporary build directory
  ci/make-tmp.sh

  # Pre-clone riscv-isa-sim and patch for GCC 13+ compatibility before building FESVR
  # GCC 13+ requires explicit <cstdint> for uint64_t in fesvr/device.h
  if [ ! -d tmp/riscv-isa-sim ]; then
    cd tmp
    git clone https://github.com/riscv/riscv-isa-sim.git
    cd riscv-isa-sim
    git checkout 35d50bc40e59ea1d5566fbd3d9226023821b1bb6
    cd ../..
  fi
  # Apply <cstdint> patch if not already present
  if ! grep -q '<cstdint>' tmp/riscv-isa-sim/fesvr/device.h; then
    sed -i '/#include <functional>/a #include <cstdint>' tmp/riscv-isa-sim/fesvr/device.h
  fi

  # Build FESVR and Spike (using system verilator and device-tree-compiler)
  ci/install-fesvr.sh
  ci/install-spike.sh

  # Build the RISC-V ISA tests and benchmarks using system toolchain
  VERSION="7cc76ea83b4f827596158c8ba0763e93da65de8f"
  cd tmp

  [ -d riscv-tests ] || git clone https://github.com/riscv/riscv-tests.git
  cd riscv-tests
  git checkout $VERSION
  git submodule update --init --recursive

  # Patch riscv-tests Makefiles for modern GCC compatibility:
  # - GCC >=12: Requires explicit zicsr extension in -march for CSR instructions
  # - GCC >=10: Defaults to -fno-common, causing tohost/fromhost symbol conflicts
  # - Add picolibc.specs and suppress implicit declaration warnings
  sed -i 's/-march=rv32g\b/-march=rv32g_zicsr/g' isa/Makefile
  sed -i 's/-march=rv64g\b/-march=rv64g_zicsr/g' isa/Makefile
  sed -i 's/RISCV_GCC_OPTS ?= -static/RISCV_GCC_OPTS ?= --specs=picolibc.specs -static -fcommon/' isa/Makefile
  sed -i 's/RISCV_GCC_OPTS ?= -DPREALLOCATE=1/RISCV_GCC_OPTS ?= --specs=picolibc.specs -march=rv64gc_zicsr -mabi=lp64 -DPREALLOCATE=1/' benchmarks/Makefile
  sed -i 's/-ffast-math -fno-common/-ffast-math -fcommon -Wno-implicit-int -Wno-implicit-function-declaration/' benchmarks/Makefile

  autoconf
  mkdir -p build

  # Replace generic syscalls.c with OpenPiton-specific versions for testbench compatibility
  cd benchmarks/common/
  rm syscalls.c util.h
  ln -s ${PITON_ROOT}/piton/verif/diag/assembly/include/riscv/ariane/syscalls.c
  ln -s ${PITON_ROOT}/piton/verif/diag/assembly/include/riscv/ariane/util.h
  cd -

  cd build
  tmp_dest=$ARIANE_ROOT/tmp
  if [ -w /tmp ]
  then
    tmp_dest=/tmp
  fi
  ../configure --prefix=$tmp_dest/riscv-tests/build

  make clean
  make isa        -j${NUM_JOBS} > /dev/null
  make benchmarks -j${NUM_JOBS} > /dev/null
  make install
  cd ${PITON_ROOT}

  echo
  echo "----------------------------------------------------------------------"
  echo "generating baremetal bootrom for Verilator simulation..."
  echo "----------------------------------------------------------------------"
  echo

  BOOTROM_DIR=${DV_ROOT}/design/chipset/rv64_platform/bootrom/baremetal
  DEVICES_XML=${DV_ROOT}/verif/env/manycore/devices_ariane.xml

  if [ ! -f "${DEVICES_XML}" ]; then
    echo "WARNING: ${DEVICES_XML} not found, skipping bootrom generation"
    echo "If bootrom.sv is missing, run: sims -rv64_platform -ariane -vlt_build"
  else
    cd ${BOOTROM_DIR}
    # riscvlib.py (via pyhplib.py) looks for devices_ariane.xml in cwd when
    # PITON_ARIANE=1 and PROTOSYN_RUNTIME_DESIGN_PATH is unset.
    # PITON_NETWORK_CONFIG is read directly (no default) by riscvlib.py.
    cp ${DEVICES_XML} ./devices_ariane.xml
    PITON_ARIANE=1 PITON_X_TILES=1 PITON_Y_TILES=1 PITON_NUM_TILES=1 \
      PITON_NETWORK_CONFIG=2dmesh_config \
      CONFIG_L1I_SIZE=16384 CONFIG_L1I_ASSOCIATIVITY=4 \
      CONFIG_L1D_SIZE=8192  CONFIG_L1D_ASSOCIATIVITY=4 \
      CONFIG_L15_SIZE=8192  CONFIG_L15_ASSOCIATIVITY=4 \
      CONFIG_L2_SIZE=65536  CONFIG_L2_ASSOCIATIVITY=4 \
      make all
    if [ $? -eq 0 ]; then
      echo "bootrom.sv generated."
    else
      echo "WARNING: bootrom.sv generation failed. Simulation build may fail."
    fi
    rm -f devices_ariane.xml
    cd ${PITON_ROOT}
  fi

  echo
  echo "----------------------------------------------------------------------"
  echo "build complete"
  echo "----------------------------------------------------------------------"
  echo

fi

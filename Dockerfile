# Copyright (c) 2024, EleutherAI
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

FROM nvidia/cuda:12.1.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

# metainformation
LABEL org.opencontainers.image.version = "2.0"
LABEL org.opencontainers.image.authors = "contact@eleuther.ai"
LABEL org.opencontainers.image.source = "https://www.github.com/eleutherai/gpt-neox"
LABEL org.opencontainers.image.licenses = " Apache-2.0"
LABEL org.opencontainers.image.base.name="docker.io/nvidia/cuda:12.1.1-devel-ubuntu22.04"

#### System package (uses default Python 3 version in Ubuntu 20.04)
RUN apt-get update -y && \
    apt-get install -y \
    git python3-dev libpython3-dev python3-pip sudo pdsh \
    htop tmux zstd software-properties-common build-essential autotools-dev \
    nfs-common pdsh cmake g++ gcc curl wget vim less unzip htop iftop iotop ca-certificates ssh \
    rsync iputils-ping net-tools libcupti-dev libmlx4-1 infiniband-diags ibutils ibverbs-utils \
    rdmacm-utils perftest rdma-core nano && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3 1 && \
    update-alternatives --install /usr/bin/pip pip /usr/bin/pip3 1 && \
    python -m pip install --upgrade pip && \
    python -m pip install gpustat

### SSH
RUN mkdir /var/run/sshd && \
    # Prevent user being kicked off after login
    sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd && \
    echo 'AuthorizedKeysFile     .ssh/authorized_keys' >> /etc/ssh/sshd_config && \
    echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config && \
    # FIX SUDO BUG: https://github.com/sudo-project/sudo/issues/42
    echo "Set disable_coredump false" >> /etc/sudo.conf

# Expose SSH port
EXPOSE 22

#### OPENMPI
ENV OPENMPI_BASEVERSION=4.1
ENV OPENMPI_VERSION=${OPENMPI_BASEVERSION}.0
RUN mkdir -p /build && \
    cd /build && \
    wget -q -O - https://download.open-mpi.org/release/open-mpi/v${OPENMPI_BASEVERSION}/openmpi-${OPENMPI_VERSION}.tar.gz | tar xzf - && \
    cd openmpi-${OPENMPI_VERSION} && \
    ./configure --prefix=/usr/local/openmpi-${OPENMPI_VERSION} && \
    make -j"$(nproc)" install && \
    ln -s /usr/local/openmpi-${OPENMPI_VERSION} /usr/local/mpi && \
    # Sanity check:
    test -f /usr/local/mpi/bin/mpic++ && \
    cd ~ && \
    rm -rf /build

# Needs to be in docker PATH if compiling other items & bashrc PATH (later)
ENV PATH=/usr/local/mpi/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/mpi/lib:/usr/local/mpi/lib64:${LD_LIBRARY_PATH}

# Create a wrapper for OpenMPI to allow running as root by default
RUN mv /usr/local/mpi/bin/mpirun /usr/local/mpi/bin/mpirun.real && \
    echo '#!/bin/bash' > /usr/local/mpi/bin/mpirun && \
    echo 'mpirun.real --allow-run-as-root --prefix /usr/local/mpi "$@"' >> /usr/local/mpi/bin/mpirun && \
    chmod a+x /usr/local/mpi/bin/mpirun

#### User account
RUN useradd --create-home --uid 1000 --shell /bin/bash mchorse && \
    usermod -aG sudo mchorse && \
    echo "mchorse ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

## SSH config and bashrc
RUN mkdir -p /home/mchorse/.ssh /job && \
    echo 'Host *' > /home/mchorse/.ssh/config && \
    echo '    StrictHostKeyChecking no' >> /home/mchorse/.ssh/config && \
    echo 'export PDSH_RCMD_TYPE=ssh' >> /home/mchorse/.bashrc && \
    echo 'export PATH=/home/mchorse/.local/bin:$PATH' >> /home/mchorse/.bashrc && \
    echo 'export PATH=/usr/local/mpi/bin:$PATH' >> /home/mchorse/.bashrc && \
    echo 'export LD_LIBRARY_PATH=/usr/local/lib:/usr/local/mpi/lib:/usr/local/mpi/lib64:$LD_LIBRARY_PATH' >> /home/mchorse/.bashrc

#### Python packages
RUN python -m pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
COPY requirements/* ./
RUN python -m pip install --no-cache-dir -r requirements.txt && pip install -r requirements-onebitadam.txt
RUN python -m pip install -r requirements-sparseattention.txt
RUN python -m pip install -r requirements-flashattention.txt
RUN python -m pip install -r requirements-wandb.txt
RUN python -m pip install protobuf==3.20.*
RUN python -m pip cache purge

## Install APEX
# Detect the architecture and install Apex accordingly
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        wget https://github.com/segyges/not-nvidia-apex/releases/download/jan-2024/apex-0.1-cp310-cp310-linux_x86_64.zip && \
        unzip ./apex-0.1-cp310-cp310-linux_x86_64.zip && \
        python -m pip install ./apex-0.1-cp310-cp310-linux_x86_64.whl; \
    else \
    # Install Apex directly from source for other architectures
        python -m pip install -r requirements-apex-pip.txt && \
        python -m pip install -v --disable-pip-version-check --no-cache-dir --no-build-isolation --config-settings --global-option=--cpp_ext --config-settings --global-option=--cuda_ext git+https://github.com/NVIDIA/apex.git@141bbf1cf362d4ca4d94f4284393e91dda5105a5; \
    fi

COPY megatron/fused_kernels/ megatron/fused_kernels
WORKDIR /megatron/fused_kernels
RUN python setup.py install

# Clear staging
RUN mkdir -p /tmp && chmod 0777 /tmp

#### SWITCH TO mchorse USER
USER mchorse
WORKDIR /home/mchorse

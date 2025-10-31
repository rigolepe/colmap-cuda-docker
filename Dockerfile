FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04
# Set non-interactive mode
ENV DEBIAN_FRONTEND=noninteractive

# ============================================================================
# System Dependencies
# ============================================================================
RUN apt-get update && apt-get install -y \
    # Build tools
    build-essential \
    cmake \
    ninja-build \
    git \
    wget \
    pkg-config \
    # COLMAP dependencies
    libboost-program-options-dev \
    libboost-filesystem-dev \
    libboost-graph-dev \
    libboost-system-dev \
    libeigen3-dev \
    libflann-dev \
    libfreeimage-dev \
    libmetis-dev \
    libgoogle-glog-dev \
    libgtest-dev \
    libsqlite3-dev \
    libglew-dev \
    qtbase5-dev \
    libqt5opengl5-dev \
    libcgal-dev \
    # CUDA Ceres dependencies
    libgflags-dev \
    libatlas-base-dev \
    libsuitesparse-dev \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    freeglut3-dev \
    libssl-dev \
    libabsl-dev \
    && rm -rf /var/lib/apt/lists/*

# ============================================================================
# 2: CUDA Environment
# ============================================================================
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=$CUDA_HOME/bin:$PATH
ENV LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH

# ============================================================================
# 3: CMake 3.28+ (Required for COLMAP 3.12+)
# ============================================================================
WORKDIR /tmp
RUN echo "=== Installing CMake 3.28.3 ===" \
    && wget -q https://github.com/Kitware/CMake/releases/download/v3.28.3/cmake-3.28.3-linux-x86_64.tar.gz \
    && tar -xzf cmake-3.28.3-linux-x86_64.tar.gz \
    && cd cmake-3.28.3-linux-x86_64 \
    && cp -r bin/* /usr/local/bin/ \
    && cp -r share/* /usr/local/share/ \
    && mkdir -p /usr/local/man \
    && cp -r man/* /usr/local/man/ \
    && cd /tmp \
    && rm -rf cmake-3.28.3* \
    && echo "✓ CMake 3.28.3 installed"

# ============================================================================
# 4: abseil-cpp (Required for Ceres)
# ============================================================================
WORKDIR /tmp
RUN echo "=== Building abseil-cpp ===" \
    && git clone --depth 1 --branch 20240116.2 https://github.com/abseil/abseil-cpp.git \
    && cd abseil-cpp \
    && mkdir build && cd build \
    && cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_CXX_STANDARD=17 \
        -DABSL_BUILD_TESTING=OFF \
        -DABSL_USE_EXTERNAL_GOOGLETEST=OFF \
    && ninja \
    && ninja install \
    && cd /tmp \
    && rm -rf abseil-cpp \
    && echo "✓ abseil-cpp installed"

# ============================================================================
# 5: cuDSS (NVIDIA CUDA Direct Sparse Solver)
# ============================================================================
WORKDIR /tmp
RUN echo "=== Installing cuDSS for GPU Bundle Adjustment ===" \
    && wget https://developer.download.nvidia.com/compute/cudss/redist/libcudss/linux-x86_64/libcudss-linux-x86_64-0.7.1.4_cuda12-archive.tar.xz \
    && tar -xf libcudss-linux-x86_64-0.7.1.4_cuda12-archive.tar.xz \
    && cp -v /tmp/libcudss-linux-x86_64-0.7.1.4_cuda12-archive/lib/libcudss*.so* /usr/local/cuda/lib64/ \
    && echo "export cudss_DIR=/tmp/libcudss-linux-x86_64-0.7.1.4_cuda12-archive/lib/cmake/cudss" >> /tmp/envfile \
    && echo "✓ cuDSS installed"

# ============================================================================
# 6: CUDA-enabled Ceres Solver 2.3.0 with cuDSS
# GPU bundle adjustment via CUDA + cuDSS
# ============================================================================
WORKDIR /tmp
RUN echo "=== Building CUDA-enabled Ceres Solver with cuDSS ===" \
    && git clone --depth 1 https://github.com/ceres-solver/ceres-solver.git \
    && cd ceres-solver \
    && mkdir build \
    && cd build \
    && . /tmp/envfile \
    && cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DUSE_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="80;86;89;90" \
        -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
        -DBUILD_TESTING=OFF \
        -DBUILD_EXAMPLES=OFF \
        -Dabsl_DIR=/usr/local/lib/cmake/absl \
    && echo "=== Ceres CMake Configuration Complete ===" \
    && ninja \
    && ninja install \
    && echo "" \
    && echo "=== Verification: Check Ceres cuDSS linking ===" \
    && ldd /usr/local/lib/libceres.so | grep cudss && echo "✓ Ceres is linked to cuDSS" || echo "⚠️  WARNING: Ceres not linked to cuDSS (will fall back to CPU)" \
    && echo "=== CUDA-enabled Ceres Solver with cuDSS installed ===" \
    && cd /tmp \
    && rm -rf ceres-solver

# ============================================================================
# 7: COLMAP 3.12.6
# with CUDA-enabled Ceres
# ============================================================================
WORKDIR /tmp
RUN echo "=== Building COLMAP 3.12.6 ===" \
    && git clone --depth 1 --branch 3.12.6 https://github.com/colmap/colmap.git \
    && cd colmap \
    && mkdir build && cd build \
    && . /tmp/envfile \
    && cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCUDA_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES="80;86;89;90" \
        -DQt5_DIR=/usr/lib/x86_64-linux-gnu/cmake/Qt5 \
        -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
        -DCeres_DIR=/usr/local/lib/cmake/Ceres \
    && ninja \
    && ninja install \
    && cd /tmp \
    && rm -rf colmap \
    && echo "✓ COLMAP 3.12.6 installed"

# ============================================================================
# 8: Verification
# ============================================================================
RUN echo "=== Verifying Base Image Build ===" \
    && echo "CMake version:" && cmake --version \
    && echo "COLMAP installed:" && colmap --help > /dev/null && echo "✓" \
    && echo "CUDA version:" && nvcc --version \
    && echo "✓ Colmap image build complete"

WORKDIR /workspace
CMD ["/bin/bash"]

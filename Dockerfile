FROM ubuntu:24.04

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
    && pip install --no-cache-dir nvidia-cudss-cu12==0.7.1.4 \
    && SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])") \
    && echo "Installed cuDSS from pip at: $SITE_PACKAGES/nvidia/cu12" \
    && echo "Copying cuDSS libraries to CUDA directories..." \
    && cp -v $SITE_PACKAGES/nvidia/cu12/lib/libcudss*.so* /usr/local/cuda/lib64/ \
    && cp -v $SITE_PACKAGES/nvidia/cu12/include/cudss*.h /usr/local/cuda/include/ \
    && echo "" \
    && echo "CRITICAL CHECK: Verify cuDSS library installation" \
    && ls -lah /usr/local/cuda/lib64/libcudss* \
    && ls -lah /usr/local/cuda/include/cudss* \
    && test -f /usr/local/cuda/lib64/libcudss.so.0 || (echo "❌ ERROR: libcudss.so.0 not found!" && exit 1) \
    && test -f /usr/local/cuda/include/cudss.h || (echo "❌ ERROR: cudss.h not found!" && exit 1) \
    && echo "Creating symlink libcudss.so -> libcudss.so.0" \
    && ln -sf /usr/local/cuda/lib64/libcudss.so.0 /usr/local/cuda/lib64/libcudss.so \
    && ldconfig \
    && ldconfig -p | grep cudss \
    && echo "✓ cuDSS 0.7.1.4 installed and verified"

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
    && cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DUSE_CUDA=ON \
        -DUSE_CUDSS=ON \
        -DCUDSS_INCLUDE_DIR=/usr/local/cuda/include \
        -DCUDSS_LIBRARY=/usr/local/cuda/lib64/libcudss.so \
        -DCMAKE_CUDA_ARCHITECTURES="80;86;89;90" \
        -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
        -DEIGEN_INCLUDE_DIR_HINTS=/usr/include/eigen3 \
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
    && echo "GLOMAP installed:" && glomap --help > /dev/null && echo "✓" \
    && echo "CUDA version:" && nvcc --version \
    && echo "✓ Colmap image build complete"

WORKDIR /workspace
CMD ["/bin/bash"]

#!/bin/bash

# CUDA 빌드 스크립트
# 컴파일 오류 해결을 위한 최적화된 빌드

echo "=== CUDA Store 빌드 시작 ==="

# 빌드 디렉토리 정리
if [ -d "build" ]; then
    echo "기존 빌드 디렉토리 정리..."
    rm -rf build/*
else
    mkdir -p build
fi

cd build

# CUDA 및 시스템 정보 확인
echo "CUDA 버전 확인:"
nvcc --version

echo "GPU 정보 확인:"
nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader

# CMake 구성 (릴리스 모드)
echo "CMake 구성 중..."
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES="61;70;75;80;86" \
    -DCMAKE_CUDA_FLAGS="-Xcompiler=-fPIC -diag-suppress 177" \
    -DCMAKE_CXX_FLAGS="-Wno-unused-variable -Wno-unused-parameter -Wno-missing-field-initializers"

if [ $? -ne 0 ]; then
    echo "CMake 구성 실패!"
    exit 1
fi

# 병렬 빌드 (CPU 코어 수의 절반 사용하여 시스템 부하 줄임)
NPROC=$(nproc)
BUILD_JOBS=$((NPROC / 2))
if [ $BUILD_JOBS -lt 1 ]; then
    BUILD_JOBS=1
fi

echo "병렬 빌드 시작 (작업 수: $BUILD_JOBS)..."
make -j$BUILD_JOBS

if [ $? -eq 0 ]; then
    echo "=== 빌드 성공! ==="
    echo "실행 파일: $(pwd)/cuda_store"
    
    # 실행 파일 정보
    echo "실행 파일 크기: $(du -h cuda_store | cut -f1)"
    echo "링크된 라이브러리:"
    ldd cuda_store | grep -E "(cuda|ssl|crypto|omp)"
else
    echo "=== 빌드 실패! ==="
    exit 1
fi
# CMake 최소 버전 요구사항 설정 (3.20 이상 필요)
cmake_minimum_required(VERSION 3.20)

# 프로젝트 이름 및 사용 언어 정의 (C++ 및 CUDA)
project(cuda_store LANGUAGES CXX CUDA)

# C++ 표준 설정
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# CUDA 표준 설정
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

# 패키지 찾기
find_package(CUDAToolkit REQUIRED)
find_package(OpenMP REQUIRED)
find_package(OpenSSL REQUIRED)  # SHA256을 위한 OpenSSL 추가

# 지원할 CUDA 아키텍처 설정 (여러 세대의 NVIDIA GPU 지원)
set(CMAKE_CUDA_ARCHITECTURES 50 52 60 61 70 72 75 80 86 87 89 90)

# 컴파일러 플래그 설정
set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -Wno-deprecated-gpu-targets")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${OpenMP_CXX_FLAGS} -Wno-unused-parameter")  # 경고 억제 추가
set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -Xcompiler=${OpenMP_CXX_FLAGS}")

# CUDA에서 OpenSSL 헤더 포함 순서 조정
set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -D__CUDA_NO_HALF_OPERATORS__ -D__CUDA_NO_HALF_CONVERSIONS__")

# 소스 파일 수집
file(GLOB_RECURSE CUDA_SOURCES "srcs/*.cu")
file(GLOB_RECURSE CXX_SOURCES "srcs/*.cpp")
file(GLOB_RECURSE C_SOURCES "srcs/*.c")

# 소스 파일 존재 확인 및 출력
message(STATUS "Found CUDA sources: ${CUDA_SOURCES}")
message(STATUS "Found C++ sources: ${CXX_SOURCES}")
message(STATUS "Found C sources: ${C_SOURCES}")

# 실행 파일 생성 (모든 소스 파일 포함)
add_executable(cuda_store 
    ${CUDA_SOURCES}
    ${CXX_SOURCES}
    ${C_SOURCES}
)

# C++17 및 CUDA 17 지원 설정
target_compile_features(cuda_store PRIVATE cxx_std_17 cuda_std_17)

# CUDA 코드 분할 컴파일 활성화
set_target_properties(cuda_store PROPERTIES 
    CUDA_SEPARABLE_COMPILATION ON
    CUDA_RESOLVE_DEVICE_SYMBOLS ON
)

# 헤더 파일 포함 디렉토리 추가
target_include_directories(cuda_store PRIVATE 
    ${CMAKE_CURRENT_SOURCE_DIR}/includes
    ${CUDAToolkit_INCLUDE_DIRS}
    ${OpenSSL_INCLUDE_DIR}
)

# 필요한 라이브러리 링크
target_link_libraries(cuda_store PRIVATE
    CUDA::cudart
    CUDA::curand      # CUDA 랜덤 생성기 (필요시)
    OpenMP::OpenMP_CXX
    OpenSSL::SSL
    OpenSSL::Crypto   # SHA256을 위한 crypto 라이브러리
)

# 컴파일 옵션 설정
target_compile_options(cuda_store PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:
        -use_fast_math          # CUDA 수학 최적화
        -lineinfo              # 디버깅 정보
        --ptxas-options=-v     # PTX 어셈블러 상세 출력
    >
    $<$<COMPILE_LANGUAGE:CXX>:
        -Wall                  # C++ 경고 활성화
        -Wextra
        -O3                    # 최적화
    >
)

# 디버그 빌드 설정
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(cuda_store PRIVATE
        $<$<COMPILE_LANGUAGE:CUDA>:-G>  # CUDA 디버그 정보
        $<$<COMPILE_LANGUAGE:CXX>:-g>   # C++ 디버그 정보
    )
endif()

# 릴리스 빌드 최적화
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    target_compile_options(cuda_store PRIVATE
        $<$<COMPILE_LANGUAGE:CUDA>:-O3>
        $<$<COMPILE_LANGUAGE:CXX>:-O3 -DNDEBUG>
    )
endif()

# 빌드 정보 출력
message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "CUDA Architectures: ${CMAKE_CUDA_ARCHITECTURES}")
message(STATUS "C++ Compiler: ${CMAKE_CXX_COMPILER}")
message(STATUS "CUDA Compiler: ${CMAKE_CUDA_COMPILER}")

# 설치 설정 (선택적)
install(TARGETS cuda_store 
    RUNTIME DESTINATION bin
)

# 사용자 정의 타겟: 프로젝트 정리
add_custom_target(clean-all
    COMMAND ${CMAKE_BUILD_TOOL} clean
    COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/CMakeFiles
    COMMENT "Cleaning all build files"
)
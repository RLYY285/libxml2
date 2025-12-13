#!/bin/bash -e

# 1. 开启调试模式 (set -x)
# 在 CI/CD 或黑盒测试环境中，这是定位问题的关键。它会打印每一行执行的命令。
set -x
set -u

# 2. 环境变量防御性默认值
# Buttercup 环境可能没有预置 OSS-Fuzz 的标准环境变量。
# 如果这些变量为空，脚本会因为 set -u 而直接崩溃，或者导致后续路径错误。
export OUT=${OUT:-"$(pwd)/out"}
export CFLAGS=${CFLAGS:-""}
export CXXFLAGS=${CXXFLAGS:-""}
export LIB_FUZZING_ENGINE=${LIB_FUZZING_ENGINE:-"-fsanitize=fuzzer"}
export ARCHITECTURE=${ARCHITECTURE:-"x86_64"}
export SANITIZER=${SANITIZER:-"address"}
export CC=${CC:-"clang"}
export CXX=${CXX:-"clang++"}

# 创建输出目录（如果不存在）
mkdir -p "$OUT"

# Add extra UBSan checks
if [ "$SANITIZER" = undefined ]; then
    extra_checks="integer,float-divide-by-zero"
    extra_cflags="-fsanitize=$extra_checks -fno-sanitize-recover=$extra_checks"
    export CFLAGS="$CFLAGS $extra_cflags"
    export CXXFLAGS="$CXXFLAGS $extra_cflags"
fi

# Don't enable zlib with MSan
if [ "$SANITIZER" = memory ]; then
    CONFIG=''
else
    CONFIG='--with-zlib'
fi

# Workaround for LeakSanitizer crashes on aarch64
if [ "$ARCHITECTURE" = "aarch64" ]; then
    export ASAN_OPTIONS=detect_leaks=0
fi

export V=1

# 3. 显式清理旧构建 (可选，但推荐)
make distclean || true

# 4. 配置 libxml2
# 增加了 --without-lzma 等选项以减少不必要的依赖干扰
./autogen.sh \
    --disable-shared \
    --without-debug \
    --without-http \
    --without-python \
    --without-lzma \
    $CONFIG

make -j$(nproc)

cd fuzz
make clean-corpus
make fuzz.o

# 5. 循环构建 Fuzzer
for fuzzer in api html lint reader regexp schema uri valid xinclude xml xpath; do
    OBJS="$fuzzer.o"
    if [ "$fuzzer" = lint ]; then
        OBJS="$OBJS ../xmllint.o ../shell.o"
    fi
    make $OBJS

    # 6. 链接修复
    # 使用 $CXX 链接，并确保链接顺序正确。
    # 注意：如果环境里没有静态 zlib (libz.a)，-Wl,-Bstatic -lz 会失败。
    # 这里添加了 fallback 逻辑或更安全的链接方式建议。
    
    echo "Linking $fuzzer..."
    $CXX $CXXFLAGS \
        $OBJS fuzz.o \
        -o "$OUT/$fuzzer" \
        $LIB_FUZZING_ENGINE \
        ../.libs/libxml2.a \
        -Wl,-Bstatic -lz -Wl,-Bdynamic || {
            echo "Static link failed, trying dynamic link for zlib..."
            $CXX $CXXFLAGS \
            $OBJS fuzz.o \
            -o "$OUT/$fuzzer" \
            $LIB_FUZZING_ENGINE \
            ../.libs/libxml2.a \
            -lz
        }

    if [ "$fuzzer" != api ]; then
        [ -e seed/$fuzzer ] || make seed/$fuzzer.stamp
        # 确保 zip 存在再执行
        if command -v zip >/dev/null 2>&1; then
            zip -j "$OUT/${fuzzer}_seed_corpus.zip" seed/$fuzzer/*
        else
            echo "Warning: zip not found, skipping corpus packaging."
        fi
    fi
done

# 7. 安全复制
# 确保文件存在再复制，避免通配符匹配失败导致脚本退出
cp *.dict *.options "$OUT/" || echo "No dict or options found to copy."

# 8. 验证产出
# 在脚本结束前检查产物，如果 $OUT 是空的，主动报错，
# 这样比让 Python 脚本报 "mv missing operand" 更容易调试。
if [ -z "$(ls -A $OUT)" ]; then
   echo "Error: Build finished but output directory $OUT is empty!"
   exit 1
fi

echo "Build successful. Artifacts in $OUT"

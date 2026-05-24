/*
 * Copyright (c) 2026, Alliance for Open Media. All rights reserved.
 *
 * This source code is subject to the terms of the BSD 2 Clause License and
 * the Alliance for Open Media Patent License 1.0. If the BSD 2 Clause License
 * was not distributed with this source code in the LICENSE file, you can
 * obtain it at www.aomedia.org/license/software. If the Alliance for Open
 * Media Patent License 1.0 was not distributed with this source code in the
 * PATENTS file, you can obtain it at www.aomedia.org/license/patent.
 */
#include "aom/aom_codec.h"
static const char* const cfg = "cmake ../.vcpkg-buildtrees/aom/src/0dfd393293-89a1dfb899.clean -G \"Ninja\" -DCMAKE_TOOLCHAIN_FILE=\"../../../Users/eli/AppData/Local/Android/Sdk/ndk/26.3.11579264/build/cmake/android.toolchain.cmake\" -DCONFIG_RUNTIME_CPU_DETECT=0 -DENABLE_DOCS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTDATA=OFF -DENABLE_TESTS=OFF -DENABLE_TOOLS=OFF";
const char *aom_codec_build_config(void) {return cfg;}

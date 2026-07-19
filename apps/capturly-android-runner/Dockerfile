# Custom GitHub Actions runner image for Capturly Android release builds.
#
# Extends the official ARC runner with exactly the toolchain the release-android
# workflow needs, so the ephemeral runner pod IS the build environment and no SDK
# is downloaded per run. Versions are pinned to apps/mobile/android/build.gradle:
#   compileSdk 36 · buildToolsVersion 36.0.0 · ndkVersion 28.2.13676358 · JDK 17
# Gradle itself comes from the repo's wrapper (9.0.0) and is cached on the PVC.
#
# Verify the base tag against the current runner release before bumping:
#   https://github.com/actions/runner/releases
FROM ghcr.io/actions/actions-runner:2.335.1

USER root

# Base tools + JDK 17 (Temurin headless)
RUN apt-get update && apt-get install -y --no-install-recommends \
      openjdk-17-jdk-headless unzip curl git ca-certificates ccache \
    && rm -rf /var/lib/apt/lists/*
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# Node 22 + pnpm (pin matches the repo's packageManager)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g pnpm@9.15.9 \
    && rm -rf /var/lib/apt/lists/*

# Android SDK: command-line tools + platform 36 + build-tools 36.0.0 + NDK
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_HOME=/opt/android-sdk
ARG ANDROID_PLATFORM=android-36
ARG ANDROID_BUILD_TOOLS=36.0.0
ARG ANDROID_NDK=28.2.13676358
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools \
    && curl -fsSL -o /tmp/cmdline-tools.zip \
       https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
    && unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools \
    && mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest \
    && rm /tmp/cmdline-tools.zip
ENV PATH=${PATH}:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools
RUN yes | sdkmanager --licenses > /dev/null \
    && sdkmanager --install \
       "platform-tools" \
       "platforms;${ANDROID_PLATFORM}" \
       "build-tools;${ANDROID_BUILD_TOOLS}" \
       "ndk;${ANDROID_NDK}" > /dev/null \
    && chown -R runner:runner ${ANDROID_SDK_ROOT}

# ccache for NDK/native compile reuse (cache dir is a mounted PVC at runtime)
ENV CMAKE_C_COMPILER_LAUNCHER=ccache
ENV CMAKE_CXX_COMPILER_LAUNCHER=ccache

USER runner

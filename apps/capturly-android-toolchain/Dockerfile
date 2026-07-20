# Toolchain image for Capturly Android release builds on Tekton.
#
# This is the STEP image the android-build catalog tasks run in — a plain
# toolchain (not an actions-runner image; that ARC image was removed with the
# Phase 0 cleanup). Bakes exactly what release-android needs so the ephemeral
# build pod IS the environment and nothing is downloaded per run. Versions pinned
# to apps/mobile/android/build.gradle: compileSdk 36 · buildToolsVersion 36.0.0 ·
# ndkVersion 28.2.13676358 · JDK 17. Gradle comes from the repo wrapper (cached
# on a PVC). Node/pnpm match the repo's packageManager.
FROM eclipse-temurin:26-jdk-jammy

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      unzip curl git ca-certificates ccache python3 python3-pip openssl \
    && rm -rf /var/lib/apt/lists/*

# Play-publish deps baked in so the step needs no runtime `pip install` (which
# would need root under set-security-context, H1). openssl (above) + python3 are
# also what the clone step uses to mint the GitHub App JWT.
RUN pip3 install --no-cache-dir --break-system-packages \
      google-api-python-client google-auth

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
       "ndk;${ANDROID_NDK}" > /dev/null

ENV CMAKE_C_COMPILER_LAUNCHER=ccache
ENV CMAKE_CXX_COMPILER_LAUNCHER=ccache

# Tekton runs steps as an arbitrary (often non-root) UID; keep the SDK readable.
RUN chmod -R a+rX ${ANDROID_SDK_ROOT}

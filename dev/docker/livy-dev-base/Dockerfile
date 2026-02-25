#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

FROM ubuntu:noble

# JAVA_VERSION: 8 for Spark 3.x, 17 for Spark 4.x
ARG JAVA_VERSION=8

# configure locale
RUN apt-get update -qq > /dev/null && apt-get install -qq --yes --no-install-recommends \
    locales && \
    locale-gen en_US.UTF-8
ENV LANG="en_US.UTF-8" \
    LANGUAGE="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    TZ=US \
    DEBIAN_FRONTEND=noninteractive

# Install necessary dependencies for build/test/debug
RUN apt-get install -qq \
    apt-transport-https \
    curl \
    git \
    libkrb5-dev \
    openjdk-${JAVA_VERSION}-jdk-headless \
    r-base \
    maven \
    software-properties-common \
    vim \
    wget \
    telnet \
    lsof

# Set JAVA_HOME based on installed JDK version
ENV JAVA_HOME=/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64

# This fixes integration tests (see original comment in prior version)
RUN rm -f /usr/bin/setsid

ENV HOME=/root

# Use system Python 3 (Ubuntu Noble ships 3.12) instead of compiling via pyenv
RUN apt-get install -y python3 python3-pip python3-venv build-essential

RUN pip3 install --break-system-packages \
        cloudpickle \
        codecov \
        flake8 \
        flaky \
        pytest \
        pytest-runner \
        requests-kerberos \
        requests \
        responses

WORKDIR /workspace

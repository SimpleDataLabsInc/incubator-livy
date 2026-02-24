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
# Standalone all-in-one Docker image for Livy.
# Clones the repo and builds Livy from source inside the container.
#
# Usage:
#   Spark 3 + Scala 2.12 (default):
#     docker build -t livy .
#
#   Spark 4 + Scala 2.13:
#     docker build -t livy \
#       --build-arg JAVA_VERSION=17 \
#       --build-arg SPARK_VERSION=4.0.0 \
#       --build-arg SPARK_SUFFIX=hadoop3 \
#       --build-arg SCALA_VERSION=2.13 .

# ============================================================
# Stage 1: Build Livy from source
# ============================================================
FROM debian:stable AS builder

ARG JAVA_VERSION=8
ARG SCALA_VERSION=2.12
ARG LIVY_REPO=https://github.com/SimpleDataLabsInc/incubator-livy.git
ARG LIVY_BRANCH=prophecy-master-refresh

RUN apt-get update && apt-get install -yq --no-install-recommends \
    curl \
    git \
    openjdk-${JAVA_VERSION}-jdk-headless \
    maven \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch ${LIVY_BRANCH} ${LIVY_REPO} /build/livy
WORKDIR /build/livy

RUN if [ "${SCALA_VERSION}" = "2.13" ]; then \
      mvn clean package -Pscala-2.13 -Pspark3 \
        -DskipTests -DskipITs -Drat.skip=true -Dmaven.test.skip=true -q; \
    else \
      mvn clean package -Pscala-2.12 -Pspark3 \
        -DskipTests -DskipITs -Drat.skip=true -Dmaven.test.skip=true -q; \
    fi

# ============================================================
# Stage 2: Runtime image
# ============================================================
FROM eclipse-temurin:17-jdk-noble

ARG JAVA_VERSION=8
ARG SCALA_VERSION=2.12
ARG LIVY_VERSION=0.10.0-incubating-SNAPSHOT
ARG SPARK_VERSION=3.2.3
# SPARK_SUFFIX: "without-hadoop" for Spark 3.x, "hadoop3" for Spark 4.x
ARG SPARK_SUFFIX=without-hadoop

RUN apt-get update && apt-get install -yq --no-install-recommends \
    curl \
    openjdk-${JAVA_VERSION}-jre-headless \
    python3 python3-pip \
    procps wget unzip \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --break-system-packages py4j 2>/dev/null \
    || python3 -m pip install py4j

ENV PYTHONHASHSEED=0
ENV PYTHONIOENCODING=UTF-8

# ---- Spark ----
ENV SPARK_HOME=/apps/spark
ENV PATH="${PATH}:${SPARK_HOME}/bin/"

RUN mkdir -p /apps && cd /apps && \
    wget -q https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-${SPARK_SUFFIX}.tgz && \
    tar -xzf spark-${SPARK_VERSION}-bin-${SPARK_SUFFIX}.tgz && \
    ln -s /apps/spark-${SPARK_VERSION}-bin-${SPARK_SUFFIX} ${SPARK_HOME} && \
    rm -f spark-${SPARK_VERSION}-bin-${SPARK_SUFFIX}.tgz

# ---- Livy (from build stage) ----
ENV LIVY_PACKAGE=apache-livy-${LIVY_VERSION}_${SCALA_VERSION}-bin
ENV LIVY_APP_PATH=/apps/${LIVY_PACKAGE}

COPY --from=builder /build/livy/assembly/target/${LIVY_PACKAGE}.zip /tmp/${LIVY_PACKAGE}.zip
RUN unzip /tmp/${LIVY_PACKAGE}.zip -d /apps && \
    mkdir -p ${LIVY_APP_PATH}/upload && \
    mkdir -p ${LIVY_APP_PATH}/logs && \
    rm -f /tmp/${LIVY_PACKAGE}.zip

# Spark 4.0 ArtifactManager creates temp dirs relative to CWD
WORKDIR /tmp

EXPOSE 8998

CMD ${LIVY_APP_PATH}/bin/livy-server

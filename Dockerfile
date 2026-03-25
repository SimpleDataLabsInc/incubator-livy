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
# Supports both Spark 3.x (Scala 2.12, JDK 8) and Spark 4.x (Scala 2.13, JDK 17).
#
# Java version and Spark tarball naming are auto-derived from SPARK_VERSION.
#
# Usage:
#   Spark 3 + Scala 2.12 (default):
#     docker build -t livy .
#
#   Spark 4 + Scala 2.13:
#     docker build -t livy \
#       --build-arg SPARK_VERSION=4.0.2 \
#       --build-arg SCALA_VERSION=2.13 .
#
#   Custom repo/branch:
#     docker build -t livy \
#       --build-arg SPARK_VERSION=4.0.2 \
#       --build-arg SCALA_VERSION=2.13 \
#       --build-arg LIVY_REPO=https://github.com/your-org/incubator-livy.git \
#       --build-arg LIVY_BRANCH=your-branch .

# ============================================================
# Stage 1: Build Livy from source
# ============================================================
FROM ubuntu:noble AS builder

ARG SPARK_VERSION=3.5.6
ARG SCALA_VERSION=2.12
ARG LIVY_VERSION=0.10.0-incubating-SNAPSHOT
ARG LIVY_REPO=https://github.com/SimpleDataLabsInc/incubator-livy.git
ARG LIVY_BRANCH=prophecy-master-refresh

ENV DEBIAN_FRONTEND=noninteractive

# Install JDK (8 for Spark 3.x, 17 for Spark 4.x) + build tools
RUN SPARK_MAJOR=$(echo "${SPARK_VERSION}" | cut -d. -f1) && \
    if [ "$SPARK_MAJOR" -ge 4 ]; then JV=17; else JV=8; fi && \
    apt-get update && apt-get install -yq --no-install-recommends \
      curl git maven python3 \
      openjdk-${JV}-jdk-headless \
    && ARCH=$(dpkg --print-architecture) \
    && ln -s /usr/lib/jvm/java-${JV}-openjdk-${ARCH} /usr/lib/jvm/java-current \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-current

RUN git clone --depth 1 --branch ${LIVY_BRANCH} ${LIVY_REPO} /build/livy
WORKDIR /build/livy

# Placeholder test-jar so repl's test-scoped dependency on
# livy-core_<scala> resolves when test compilation is skipped.
RUN mkdir -p /tmp/empty-classes && \
    jar cf /tmp/empty-tests.jar -C /tmp/empty-classes . && \
    mvn install:install-file -q \
      -Dfile=/tmp/empty-tests.jar \
      -DgroupId=org.apache.livy \
      -DartifactId=livy-core_${SCALA_VERSION} \
      -Dversion=${LIVY_VERSION} \
      -Dpackaging=jar \
      -Dclassifier=tests

RUN SPARK_MAJOR=$(echo "${SPARK_VERSION}" | cut -d. -f1) && \
    if [ "$SPARK_MAJOR" -ge 4 ]; then SPARK_PROFILE=spark4; else SPARK_PROFILE=spark3; fi && \
    if [ "${SCALA_VERSION}" = "2.13" ]; then SCALA_PROFILE=scala-2.13; else SCALA_PROFILE=scala-2.12; fi && \
    mvn clean package -P${SCALA_PROFILE} -P${SPARK_PROFILE} \
      -Dspark.version=${SPARK_VERSION} \
      -pl '!coverage,!python-api' \
      -DskipTests -DskipITs -Dmaven.test.skip=true -Drat.skip=true -q

# ============================================================
# Stage 2: Runtime image
# ============================================================
FROM ubuntu:noble AS runtime

ARG SPARK_VERSION=3.5.6
ARG SCALA_VERSION=2.12
ARG LIVY_VERSION=0.10.0-incubating-SNAPSHOT

ENV DEBIAN_FRONTEND=noninteractive

# Install JRE (8 for Spark 3.x, 17 for Spark 4.x) + runtime deps
RUN SPARK_MAJOR=$(echo "${SPARK_VERSION}" | cut -d. -f1) && \
    if [ "$SPARK_MAJOR" -ge 4 ]; then JV=17; else JV=8; fi && \
    apt-get update && apt-get install -yq --no-install-recommends \
      curl wget unzip procps tini \
      python3 python3-pip \
      openjdk-${JV}-jre-headless \
    && ARCH=$(dpkg --print-architecture) \
    && ln -s /usr/lib/jvm/java-${JV}-openjdk-${ARCH} /usr/lib/jvm/java-current \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --break-system-packages py4j 2>/dev/null \
    || python3 -m pip install py4j

ENV JAVA_HOME=/usr/lib/jvm/java-current
ENV PYTHONHASHSEED=0
ENV PYTHONIOENCODING=UTF-8

# ---- Spark ----
# Spark 3.x tarballs: spark-<ver>-bin-without-hadoop.tgz
# Spark 4.x tarballs: spark-<ver>-bin-hadoop3.tgz
ENV SPARK_HOME=/apps/spark
ENV PATH="${PATH}:${SPARK_HOME}/bin"

RUN SPARK_MAJOR=$(echo "${SPARK_VERSION}" | cut -d. -f1) && \
    if [ "$SPARK_MAJOR" -ge 4 ]; then SUFFIX=hadoop3; else SUFFIX=without-hadoop; fi && \
    SPARK_TGZ="spark-${SPARK_VERSION}-bin-${SUFFIX}.tgz" && \
    SPARK_URL="https://dlcdn.apache.org/spark/spark-${SPARK_VERSION}/${SPARK_TGZ}" && \
    SPARK_ARCHIVE="https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/${SPARK_TGZ}" && \
    mkdir -p /apps && cd /apps && \
    (wget -q -T 120 "${SPARK_URL}" || wget -q -T 600 "${SPARK_ARCHIVE}") && \
    tar -xzf "${SPARK_TGZ}" && \
    ln -s /apps/spark-${SPARK_VERSION}-bin-${SUFFIX} ${SPARK_HOME} && \
    rm -f "${SPARK_TGZ}"

# ---- Livy (from build stage) ----
ENV LIVY_PACKAGE=apache-livy-${LIVY_VERSION}_${SCALA_VERSION}-bin
ENV LIVY_APP_PATH=/apps/${LIVY_PACKAGE}

COPY --from=builder /build/livy/assembly/target/${LIVY_PACKAGE}.zip /tmp/${LIVY_PACKAGE}.zip

RUN unzip -q /tmp/${LIVY_PACKAGE}.zip -d /apps && \
    mkdir -p ${LIVY_APP_PATH}/upload && \
    mkdir -p ${LIVY_APP_PATH}/logs && \
    rm -f /tmp/${LIVY_PACKAGE}.zip

WORKDIR /tmp

EXPOSE 8998

CMD ${LIVY_APP_PATH}/bin/livy-server

# ============================================================
# Stage 3: Integration test (optional)
#
# Only runs when targeted explicitly:
#   docker build --target test -t livy-test \
#     --build-arg SPARK_VERSION=4.0.2 --build-arg SCALA_VERSION=2.13 .
#
# Normal builds skip this stage entirely:
#   docker build -t livy \
#     --build-arg SPARK_VERSION=4.0.2 --build-arg SCALA_VERSION=2.13 .
# ============================================================
FROM runtime AS test

COPY dev/test-scala213-interpreter.sh /opt/test-scala213-interpreter.sh
RUN chmod +x /opt/test-scala213-interpreter.sh

RUN bash -c '\
  ${LIVY_APP_PATH}/bin/livy-server &  \
  LIVY_PID=$! ; \
  echo "Waiting for Livy (pid=$LIVY_PID) to start..." ; \
  for i in $(seq 1 60); do \
    curl -sf http://localhost:8998/version >/dev/null 2>&1 && break ; \
    sleep 2 ; \
  done ; \
  if ! curl -sf http://localhost:8998/version >/dev/null 2>&1; then \
    echo "ERROR: Livy failed to start within 120s" ; \
    kill $LIVY_PID 2>/dev/null ; \
    exit 1 ; \
  fi ; \
  echo "Livy is up. Running integration tests..." ; \
  /opt/test-scala213-interpreter.sh http://localhost:8998 ; \
  TEST_EXIT=$? ; \
  kill $LIVY_PID 2>/dev/null ; \
  wait $LIVY_PID 2>/dev/null ; \
  exit $TEST_EXIT \
'

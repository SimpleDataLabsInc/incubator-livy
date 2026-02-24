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

# ============================================================
# Stage 1: Build Livy from source (cloned from git)
# Uses livy-dev-base which already has Maven + JDK installed.
# ============================================================
FROM livy-dev-base:latest AS builder

ARG SCALA_VERSION=2.12
ARG LIVY_REPO=https://github.com/SimpleDataLabsInc/incubator-livy.git
ARG LIVY_BRANCH=prophecy-master-refresh

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
# Stage 2: Runtime image with just Livy binaries
# ============================================================
FROM livy-dev-spark:latest

ARG SCALA_VERSION=2.12
ARG LIVY_VERSION=0.10.0-incubating-SNAPSHOT
ARG ROOT_PATH=/opt

RUN apt-get update && apt-get install -y unzip && rm -rf /var/lib/apt/lists/*

ENV LIVY_HOME=${ROOT_PATH}/livy
ENV LIVY_PACKAGE=apache-livy-${LIVY_VERSION}_${SCALA_VERSION}-bin

COPY --from=builder /build/livy/assembly/target/${LIVY_PACKAGE}.zip /tmp/${LIVY_PACKAGE}.zip

RUN unzip /tmp/${LIVY_PACKAGE}.zip 1>/dev/null \
  && mv ${LIVY_PACKAGE} ${ROOT_PATH}/ \
  && ln -s ${ROOT_PATH}/${LIVY_PACKAGE} ${LIVY_HOME} \
  && chown -R root:root ${LIVY_HOME} \
  && rm /tmp/${LIVY_PACKAGE}.zip

# Spark 4.0 ArtifactManager creates temp dirs relative to CWD.
WORKDIR /tmp

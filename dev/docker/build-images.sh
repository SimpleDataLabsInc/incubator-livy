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

set -ex

SCRIPT_DIR=$(realpath "$(dirname ${0})")
echo "Running from ${SCRIPT_DIR}"

APACHE_ARCHIVE_ROOT=http://archive.apache.org/dist

# ---- Configurable versions (override via environment) ----
HADOOP_VERSION=${HADOOP_VERSION:-3.3.1}
SPARK_VERSION=${SPARK_VERSION:-3.2.3}
SCALA_VERSION=${SCALA_VERSION:-2.12}
HIVE_VERSION=${HIVE_VERSION:-2.3.9}
LIVY_VERSION=${LIVY_VERSION:-0.10.0-incubating-SNAPSHOT}
LIVY_REPO=${LIVY_REPO:-https://github.com/SimpleDataLabsInc/incubator-livy.git}
LIVY_BRANCH=${LIVY_BRANCH:-prophecy-master-refresh}

# Spark 4.x uses "spark-4.0.0-bin-hadoop3.tgz" naming;
# Spark 3.x uses "spark-3.2.3-bin-without-hadoop.tgz" naming.
SPARK_MAJOR=$(echo "${SPARK_VERSION}" | cut -d. -f1)
if [ "${SPARK_MAJOR}" -ge 4 ]; then
  SPARK_PACKAGE="spark-${SPARK_VERSION}-bin-hadoop3.tgz"
  JAVA_VERSION=${JAVA_VERSION:-17}
else
  SPARK_PACKAGE="spark-${SPARK_VERSION}-bin-without-hadoop.tgz"
  JAVA_VERSION=${JAVA_VERSION:-8}
fi

HADOOP_PACKAGE="hadoop-${HADOOP_VERSION}.tar.gz"
HIVE_PACKAGE="apache-hive-${HIVE_VERSION}-bin.tar.gz"

echo "=== Build configuration ==="
echo "  HADOOP_VERSION : ${HADOOP_VERSION}"
echo "  SPARK_VERSION  : ${SPARK_VERSION} (major=${SPARK_MAJOR})"
echo "  SCALA_VERSION  : ${SCALA_VERSION}"
echo "  JAVA_VERSION   : ${JAVA_VERSION}"
echo "  LIVY_VERSION   : ${LIVY_VERSION}"
echo "  LIVY_REPO      : ${LIVY_REPO}"
echo "  LIVY_BRANCH    : ${LIVY_BRANCH}"
echo "  SPARK_PACKAGE  : ${SPARK_PACKAGE}"
echo "==========================="

# ---- Download dependencies ----
if [ ! -f "${SCRIPT_DIR}/livy-dev-spark/${HADOOP_PACKAGE}" ]; then
    curl --fail -L --retry 3 -o "${SCRIPT_DIR}/livy-dev-spark/${HADOOP_PACKAGE}" \
      "${APACHE_ARCHIVE_ROOT}/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_PACKAGE}"
fi

if [ ! -f "${SCRIPT_DIR}/livy-dev-spark/${HIVE_PACKAGE}" ]; then
    curl --fail -L --retry 3 -o "${SCRIPT_DIR}/livy-dev-spark/${HIVE_PACKAGE}" \
      "${APACHE_ARCHIVE_ROOT}/hive/hive-${HIVE_VERSION}/${HIVE_PACKAGE}"
fi

if [ ! -f "${SCRIPT_DIR}/livy-dev-spark/${SPARK_PACKAGE}" ]; then
    curl --fail -L --retry 3 -o "${SCRIPT_DIR}/livy-dev-spark/${SPARK_PACKAGE}" \
      "${APACHE_ARCHIVE_ROOT}/spark/spark-${SPARK_VERSION}/${SPARK_PACKAGE}"
fi

# ---- Build Docker images ----
DOCKER_PLATFORM=${DOCKER_PLATFORM:-linux/amd64}

# Layer 1: Base (JDK + Maven + Python)
docker build --platform ${DOCKER_PLATFORM} -t livy-dev-base "${SCRIPT_DIR}/livy-dev-base/" \
  --build-arg JAVA_VERSION=${JAVA_VERSION}

# Layer 2: Spark + Hadoop
docker build --platform ${DOCKER_PLATFORM} -t livy-dev-spark "${SCRIPT_DIR}/livy-dev-spark/" \
  --build-arg HADOOP_VERSION=${HADOOP_VERSION} \
  --build-arg SPARK_VERSION=${SPARK_VERSION} \
  --build-arg SPARK_MAJOR=${SPARK_MAJOR}

# Layer 3: Livy (cloned from git and built from source inside the container)
docker build --platform ${DOCKER_PLATFORM} -t livy-dev-server "${SCRIPT_DIR}/livy-dev-server/" \
  --build-arg SCALA_VERSION=${SCALA_VERSION} \
  --build-arg LIVY_VERSION=${LIVY_VERSION} \
  --build-arg LIVY_REPO=${LIVY_REPO} \
  --build-arg LIVY_BRANCH=${LIVY_BRANCH}

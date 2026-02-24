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
FROM livy-dev-base:latest

ARG HADOOP_VERSION=3.3.1
ARG SPARK_VERSION=3.2.3
# SPARK_MAJOR: 3 or 4, controls tarball naming and Hadoop bundling
ARG SPARK_MAJOR=3
ARG ROOT_PATH=/opt

RUN mkdir -p ${ROOT_PATH}

# ---- Hadoop ----
ENV HADOOP_HOME=${ROOT_PATH}/hadoop
ENV HADOOP_CONF_DIR=${HADOOP_HOME}/etc/hadoop
ENV PATH=${PATH}:${HADOOP_HOME}/bin
ENV HADOOP_PACKAGE=hadoop-${HADOOP_VERSION}

COPY ${HADOOP_PACKAGE}.tar.gz ${HADOOP_PACKAGE}.tar.gz

RUN gunzip ${HADOOP_PACKAGE}.tar.gz \
 && tar -xf ${HADOOP_PACKAGE}.tar -C ${ROOT_PATH}/ \
 && ln -s ${ROOT_PATH}/${HADOOP_PACKAGE} ${HADOOP_HOME} \
 && rm -rf ${HADOOP_HOME}/share/doc \
 && chown -R root:root ${HADOOP_HOME} \
 && rm ${HADOOP_PACKAGE}.tar

# ---- Spark ----
# Spark 4.x: spark-4.0.0-bin-hadoop3.tgz (bundles Hadoop client jars)
# Spark 3.x: spark-3.2.3-bin-without-hadoop.tgz (needs SPARK_DIST_CLASSPATH)
ENV SPARK_HOME=${ROOT_PATH}/spark
ENV PATH=${PATH}:${SPARK_HOME}/bin

# Spark 3.x needs Hadoop on the classpath; Spark 4.x bundles it.
ENV SPARK_DIST_CLASSPATH="${HADOOP_HOME}/etc/hadoop/*:${HADOOP_HOME}/share/hadoop/common/lib/*:${HADOOP_HOME}/share/hadoop/common/*:${HADOOP_HOME}/share/hadoop/hdfs/*:${HADOOP_HOME}/share/hadoop/hdfs/lib/*:${HADOOP_HOME}/share/hadoop/hdfs/*:${HADOOP_HOME}/share/hadoop/yarn/lib/*:${HADOOP_HOME}/share/hadoop/yarn/*:${HADOOP_HOME}/share/hadoop/mapreduce/lib/*:${HADOOP_HOME}/share/hadoop/mapreduce/*:${HADOOP_HOME}/share/hadoop/tools/lib/*"

# Copy whichever tarball was downloaded by build-images.sh
COPY spark-${SPARK_VERSION}-bin-*.tgz /tmp/spark.tgz

RUN tar -xzf /tmp/spark.tgz -C ${ROOT_PATH}/ \
 && ln -s ${ROOT_PATH}/spark-${SPARK_VERSION}-bin-* ${SPARK_HOME} \
 && chown -R root:root ${SPARK_HOME} \
 && rm /tmp/spark.tgz

WORKDIR ${SPARK_HOME}

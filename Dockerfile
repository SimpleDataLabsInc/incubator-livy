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
# Builds Docker image for livy

FROM ubuntu:latest
RUN apt-get update && apt-get install -yq --no-install-recommends \
    curl \
    git \
    openjdk-8-jdk \
    maven \
    r-base \
    r-base-core \
    make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev llvm libncurses5-dev  libncursesw5-dev xz-utils tk-dev \
    libffi-dev \
    procps wget curl telnet vim && \
    rm -rf /var/lib/apt/lists/*

ENV PYTHON_VERSION 3.8.10
RUN curl -LJO https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tar.xz && tar -xf Python-$PYTHON_VERSION.tar.xz
#WORKDIR Python-$PYTHON_VERSION
RUN cd Python-$PYTHON_VERSION && ./configure --enable-optimizations && make -j 8 && make altinstall

RUN update-alternatives --install /usr/bin/python python /usr/local/bin/python3.8 3
RUN cp /usr/bin/python /usr/bin/python3

# Install pip for Python$PYTHON_VERSION
RUN curl https://bootstrap.pypa.io/pip/get-pip.py -o get-pip.py
RUN python3 get-pip.py
RUN python3 -m pip install py4j  --break-system-packages
#RUN python3 -m pip install --upgrade setuptools
# RUN ln -s $(which python3) /usr/bin/python
ENV PYTHONHASHSEED 0
ENV PYTHONIOENCODING UTF-8
ENV PIP_DISABLE_PIP_VERSION_CHECK 1

ENV HADOOP_FULL_VERSION 2.7.3
ENV AWS_SDK_VERSION 1.7.4
ENV AZURE_SDK_VERSION 2.0.0

RUN mvn dependency:get -DgroupId=org.apache.hadoop -DartifactId=hadoop-aws -Dversion=$HADOOP_FULL_VERSION
RUN mvn dependency:get -DgroupId=com.amazonaws -DartifactId=aws-java-sdk -Dversion=$AWS_SDK_VERSION
RUN mvn dependency:get -DgroupId=org.apache.hadoop -DartifactId=hadoop-azure -Dversion=$HADOOP_FULL_VERSION
RUN mvn dependency:get -DgroupId=com.microsoft.azure -DartifactId=azure-storage -Dversion=$AZURE_SDK_VERSION

#RUN pip3 install matplotlib pandas
ARG SPARK_VERSION
ARG HADOOP_VERSION=hadoop2.7
ENV SPARK_BUILD_VERSION=$SPARK_VERSION
ENV HADOOP_ASSOCIATION=$HADOOP_VERSION
ENV SPARK_HOME /apps/spark-${SPARK_BUILD_VERSION}-bin-${HADOOP_ASSOCIATION}
ENV SPARK_BUILD_PATH /apps/build/spark

RUN mkdir -p /apps/build && cd /apps && \
wget https://archive.apache.org/dist/spark/spark-${SPARK_BUILD_VERSION}/spark-${SPARK_BUILD_VERSION}-bin-${HADOOP_ASSOCIATION}.tgz && \
tar -xvzf spark-${SPARK_BUILD_VERSION}-bin-${HADOOP_ASSOCIATION}.tgz && \
rm -rf spark-${SPARK_BUILD_VERSION}-bin-${HADOOP_ASSOCIATION}.tgz

# ----------
# Build Livy
# ----------
ARG LIVY_VERSION
ENV LIVY_BUILD_VERSION=$LIVY_VERSION
ENV LIVY_APP_PATH /apps/apache-livy-$LIVY_BUILD_VERSION-bin
ENV SPARK_HOME=/apps/spark-${SPARK_BUILD_VERSION}-bin-${HADOOP_ASSOCIATION}
ENV PATH="${PATH}:/apps/spark-${SPARK_BUILD_VERSION}-bin-${HADOOP_ASSOCIATION}/bin/"

COPY assembly/target/apache-livy-${LIVY_BUILD_VERSION}-bin.zip apache-livy-${LIVY_BUILD_VERSION}-bin.zip
RUN unzip apache-livy-${LIVY_BUILD_VERSION}-bin.zip -d /apps && \
    	mkdir -p $LIVY_APP_PATH/upload && \
      mkdir -p $LIVY_APP_PATH/logs && rm -rf apache-livy-${LIVY_BUILD_VERSION}-bin.zip

RUN cp ~/.m2/repository/org/apache/hadoop/hadoop-aws/$HADOOP_FULL_VERSION/hadoop-aws-$HADOOP_FULL_VERSION.jar $LIVY_APP_PATH/jars/
RUN cp ~/.m2/repository/com/amazonaws/aws-java-sdk/$AWS_SDK_VERSION/aws-java-sdk-$AWS_SDK_VERSION.jar $LIVY_APP_PATH/jars/
RUN cp ~/.m2/repository/org/apache/hadoop/hadoop-azure/$HADOOP_FULL_VERSION/hadoop-azure-$HADOOP_FULL_VERSION.jar $LIVY_APP_PATH/jars/
RUN cp ~/.m2/repository/com/microsoft/azure/azure-storage/$AZURE_SDK_VERSION/azure-storage-$AZURE_SDK_VERSION.jar $LIVY_APP_PATH/jars/

RUN cp ~/.m2/repository/org/apache/hadoop/hadoop-aws/$HADOOP_FULL_VERSION/hadoop-aws-$HADOOP_FULL_VERSION.jar $SPARK_HOME/jars/
RUN cp ~/.m2/repository/com/amazonaws/aws-java-sdk/$AWS_SDK_VERSION/aws-java-sdk-$AWS_SDK_VERSION.jar $SPARK_HOME/jars/
RUN cp ~/.m2/repository/org/apache/hadoop/hadoop-azure/$HADOOP_FULL_VERSION/hadoop-azure-$HADOOP_FULL_VERSION.jar $SPARK_HOME/jars/
RUN cp ~/.m2/repository/com/microsoft/azure/azure-storage/$AZURE_SDK_VERSION/azure-storage-$AZURE_SDK_VERSION.jar $SPARK_HOME/jars/

# Remove log4j2 and keep log4j1
RUN rm -rf /apps/apache-livy-0.8.0-incubating-SNAPSHOT-bin/jars/log4j-slf4j-impl-2.18.0.jar /apps/apache-livy-0.8.0-incubating-SNAPSHOT-bin/jars/log4j-core-2.18.0.jar /apps/apache-livy-0.8.0-incubating-SNAPSHOT-bin/jars/log4j-api-2.18.0.jar /apps/apache-livy-0.8.0-incubating-SNAPSHOT-bin/jars/log4j-1.2-api-2.18.0.jar
EXPOSE 8998
EXPOSE 11000

CMD $LIVY_APP_PATH/bin/livy-server

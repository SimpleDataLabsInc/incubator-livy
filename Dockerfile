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

FROM debian:stable
RUN echo "deb http://deb.debian.org/debian/ sid main" | tee /etc/apt/sources.list.d/jdk8.list
RUN apt-get update && apt-get install -yq --no-install-recommends --force-yes \
    curl \
    git \
    openjdk-8-jdk \
    maven \
    python3 python3-setuptools \
    r-base \
    r-base-core \
    make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev llvm xz-utils tk-dev \
    libffi-dev \
    procps wget curl telnet vim && \
    rm -rf /var/lib/apt/lists/*

ARG PYTHON_VERSION=3.7.17
ENV PYTHON_VERSION=$PYTHON_VERSION

RUN curl -LJO https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tar.xz && tar -xf Python-$PYTHON_VERSION.tar.xz
#WORKDIR Python-$PYTHON_VERSION
RUN cd Python-$PYTHON_VERSION && ./configure --enable-optimizations && make -j8 build_all && make -j8 altinstall

RUN update-alternatives --install /usr/bin/python python /usr/local/bin/python3.7 3
RUN cp /usr/bin/python /usr/bin/python3

# Install pip for Python$PYTHON_VERSION
RUN curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
RUN python get-pip.py
RUN python -m pip install py4j
RUN python -m pip install --upgrade pip

ENV PYTHONHASHSEED 0
ENV PYTHONIOENCODING UTF-8
ENV PIP_DISABLE_PIP_VERSION_CHECK 1

ENV HADOOP_FULL_VERSION 2.7.3
ENV AWS_SDK_VERSION 1.7.4
ENV AZURE_SDK_VERSION 2.0.0
ENV POSTGRES_DRIVER_VERSION 42.6.0


#RUN pip3 install matplotlib pandas
ARG SPARK_VERSION
ARG HADOOP_VERSION=2.7
ENV SPARK_BUILD_VERSION=$SPARK_VERSION
ENV HADOOP_ASSOCIATION="hadoop$HADOOP_VERSION"
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
ENV LIVY_HOME /apps/apache-livy-$LIVY_BUILD_VERSION-bin
ENV SPARK_HOME=/apps/spark-${SPARK_BUILD_VERSION}-bin-${HADOOP_ASSOCIATION}
ENV PATH="${PATH}:/apps/spark-${SPARK_BUILD_VERSION}-bin-${HADOOP_ASSOCIATION}/bin/"

COPY assembly/target/apache-livy-${LIVY_BUILD_VERSION}-bin.zip apache-livy-${LIVY_BUILD_VERSION}-bin.zip
RUN unzip apache-livy-${LIVY_BUILD_VERSION}-bin.zip -d /apps && \
    	mkdir -p $LIVY_HOME/upload && \
      mkdir -p $LIVY_HOME/logs && rm -rf apache-livy-${LIVY_BUILD_VERSION}-bin.zip

RUN mvn dependency:get -DgroupId=org.apache.hadoop -DartifactId=hadoop-aws -Dversion=$HADOOP_FULL_VERSION
RUN mvn dependency:get -DgroupId=com.amazonaws -DartifactId=aws-java-sdk -Dversion=$AWS_SDK_VERSION
RUN mvn dependency:get -DgroupId=org.apache.hadoop -DartifactId=hadoop-azure -Dversion=$HADOOP_FULL_VERSION
RUN mvn dependency:get -DgroupId=com.microsoft.azure -DartifactId=azure-storage -Dversion=$AZURE_SDK_VERSION
RUN mvn dependency:get -DgroupId=org.postgresql -DartifactId=postgresql -Dversion=$POSTGRES_DRIVER_VERSION


RUN cp ~/.m2/repository/org/apache/hadoop/hadoop-aws/$HADOOP_FULL_VERSION/hadoop-aws-$HADOOP_FULL_VERSION.jar $LIVY_HOME/jars/
RUN cp ~/.m2/repository/com/amazonaws/aws-java-sdk/$AWS_SDK_VERSION/aws-java-sdk-$AWS_SDK_VERSION.jar $LIVY_HOME/jars/
RUN cp ~/.m2/repository/org/apache/hadoop/hadoop-azure/$HADOOP_FULL_VERSION/hadoop-azure-$HADOOP_FULL_VERSION.jar $LIVY_HOME/jars/
RUN cp ~/.m2/repository/com/microsoft/azure/azure-storage/$AZURE_SDK_VERSION/azure-storage-$AZURE_SDK_VERSION.jar $LIVY_HOME/jars/

RUN cp ~/.m2/repository/org/apache/hadoop/hadoop-aws/$HADOOP_FULL_VERSION/hadoop-aws-$HADOOP_FULL_VERSION.jar $SPARK_HOME/jars/
RUN cp ~/.m2/repository/com/amazonaws/aws-java-sdk/$AWS_SDK_VERSION/aws-java-sdk-$AWS_SDK_VERSION.jar $SPARK_HOME/jars/
RUN cp ~/.m2/repository/org/apache/hadoop/hadoop-azure/$HADOOP_FULL_VERSION/hadoop-azure-$HADOOP_FULL_VERSION.jar $SPARK_HOME/jars/
RUN cp ~/.m2/repository/com/microsoft/azure/azure-storage/$AZURE_SDK_VERSION/azure-storage-$AZURE_SDK_VERSION.jar $SPARK_HOME/jars/
RUN cp ~/.m2/repository/org/postgresql/postgresql/$POSTGRES_DRIVER_VERSION/postgresql-$POSTGRES_DRIVER_VERSION.jar $SPARK_HOME/jars/

# todo move up
COPY entrypoint /
RUN chmod +x /entrypoint

EXPOSE 8998
EXPOSE 11000

CMD /entrypoint

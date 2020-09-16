FROM debian:stretch

RUN apt-get update && apt-get install -yq --no-install-recommends --force-yes \
    curl \
    git \
    openjdk-8-jdk \
    maven \
    python2.7 python2.7-setuptools \
    python3 python3-setuptools \
    r-base \
    r-base-core \
    procps wget curl telnet vim && \
    rm -rf /var/lib/apt/lists/*

# Install pip for Python3
RUN easy_install3 pip py4j
RUN pip install --upgrade setuptools

ENV PYTHONHASHSEED 0
ENV PYTHONIOENCODING UTF-8
ENV PIP_DISABLE_PIP_VERSION_CHECK 1

RUN pip install matplotlib pandas
ENV SPARK_BUILD_VERSION 2.4.0
ENV HADOOP_ASSOCIATION hadoop2.7
ENV SPARK_HOME /apps/spark-${SPARK_BUILD_VERSION}-bin-${HADOOP_ASSOCIATION}
ENV SPARK_BUILD_PATH /apps/build/spark

RUN mkdir -p /apps/build && cd /apps && \
wget https://archive.apache.org/dist/spark/spark-${SPARK_BUILD_VERSION}/spark-${SPARK_BUILD_VERSION}-bin-${HADOOP_ASSOCIATION}.tgz && \
tar -xvzf spark-${SPARK_BUILD_VERSION}-bin-${HADOOP_ASSOCIATION}.tgz && \
rm -rf spark-${SPARK_BUILD_VERSION}-bin-${HADOOP_ASSOCIATION}.tgz

# ----------
# Build Livy
# ----------
ENV LIVY_BUILD_VERSION 0.7.0-incubating
ENV LIVY_APP_PATH /apps/apache-livy-$LIVY_BUILD_VERSION-bin


# Install setuptools for Python 2.7 for Livy
RUN curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py && \
    python get-pip.py --user && \
    rm get-pip.py && \
    python -m pip install --upgrade setuptools


COPY assembly/target/apache-livy-${LIVY_BUILD_VERSION}-bin.zip /
RUN unzip apache-livy-${LIVY_BUILD_VERSION}-bin.zip -d /apps && \
    	mkdir -p $LIVY_APP_PATH/upload && \
      mkdir -p $LIVY_APP_PATH/logs && rm -rf apache-livy-${LIVY_BUILD_VERSION}-bin.zip

ENV HADOOP_FULL_VERSION 2.7.3
ENV AWS_SDK_VERSION 1.7.4
ENV AZURE_SDK_VERSION 2.0.0

RUN mvn dependency:get -DgroupId=org.apache.hadoop -DartifactId=hadoop-aws -Dversion=$HADOOP_FULL_VERSION
RUN mvn dependency:get -DgroupId=com.amazonaws -DartifactId=aws-java-sdk -Dversion=$AWS_SDK_VERSION

RUN mvn dependency:get -DgroupId=org.apache.hadoop -DartifactId=hadoop-azure -Dversion=$HADOOP_FULL_VERSION
RUN mvn dependency:get -DgroupId=com.microsoft.azure -DartifactId=azure-storage -Dversion=$AZURE_SDK_VERSION

RUN cp ~/.m2/repository/org/apache/hadoop/hadoop-aws/$HADOOP_FULL_VERSION/hadoop-aws-$HADOOP_FULL_VERSION.jar $LIVY_APP_PATH/jars/
RUN cp ~/.m2/repository/com/amazonaws/aws-java-sdk/$AWS_SDK_VERSION/aws-java-sdk-$AWS_SDK_VERSION.jar $LIVY_APP_PATH/jars/
RUN cp ~/.m2/repository/org/apache/hadoop/hadoop-azure/$HADOOP_FULL_VERSION/hadoop-azure-$HADOOP_FULL_VERSION.jar $LIVY_APP_PATH/jars/
RUN cp ~/.m2/repository/com/microsoft/azure/azure-storage/$AZURE_SDK_VERSION/azure-storage-$AZURE_SDK_VERSION.jar $LIVY_APP_PATH/jars/

RUN cp ~/.m2/repository/org/apache/hadoop/hadoop-aws/$HADOOP_FULL_VERSION/hadoop-aws-$HADOOP_FULL_VERSION.jar $SPARK_HOME/jars/
RUN cp ~/.m2/repository/com/amazonaws/aws-java-sdk/$AWS_SDK_VERSION/aws-java-sdk-$AWS_SDK_VERSION.jar $SPARK_HOME/jars/
RUN cp ~/.m2/repository/org/apache/hadoop/hadoop-azure/$HADOOP_FULL_VERSION/hadoop-azure-$HADOOP_FULL_VERSION.jar $SPARK_HOME/jars/
RUN cp ~/.m2/repository/com/microsoft/azure/azure-storage/$AZURE_SDK_VERSION/azure-storage-$AZURE_SDK_VERSION.jar $SPARK_HOME/jars/

RUN update-alternatives --install /usr/bin/python python /usr/bin/python2.7 2
# override with python3
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.5 3

EXPOSE 8998
EXPOSE 11000

CMD $LIVY_APP_PATH/bin/livy-server

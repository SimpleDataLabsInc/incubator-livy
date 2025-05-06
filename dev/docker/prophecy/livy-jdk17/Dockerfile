##########################
# Stage 1 – build Livy
##########################
FROM maven:3.9.7-eclipse-temurin-17 AS builder

# --- Build‑time parameters -------------
ARG LIVY_GIT=https://github.com/SimpleDataLabsInc/incubator-livy.git
ARG LIVY_BRANCH=ashvjit/apache-master-actual
ARG SPARK_VERSION=3.4.0
ARG SCALA_BINARY=2.12
# ---------------------------------------

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
     build-essential libkrb5-dev python3.10 python3.10-distutils python3-pip python3.10-venv && \
    ln -s /usr/bin/python3.10 /usr/bin/python && \
    python3.10 -m pip install --no-cache-dir --upgrade pip Cython==0.29.37 'setuptools<66' wheel && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone --depth 1 --single-branch --branch "${LIVY_BRANCH}" "${LIVY_GIT}" livy

RUN mvn -T1C -f livy -Pspark3.4-java17 -DskipTests -DskipITs -pl '!python-api,!coverage,!examples' -am clean package

##########################
# Stage 2 – runtime
##########################
FROM openjdk:17-jdk-slim

ENV LIVY_HOME=/opt/livy \
    SPARK_HOME=/opt/spark \
    PYTHON_VERSION=3.10 \
    PYSPARK_PYTHON=/usr/bin/python3.10 \
    PYSPARK_DRIVER_PYTHON=/usr/bin/python3.10 \
    PATH="/opt/livy/bin:/opt/spark/bin:${PATH}" \
    SPARK_OPTS="--add-opens java.base/java.lang.invoke=ALL-UNNAMED --add-opens java.base/java.util.regex=ALL-UNNAMED"

# Single block for all OS dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    python3.10 \
    python3-pip \
    wget \
    curl \
    tini \
    procps \
    zip \
    unzip && \
    # Ensure python3.10 is the default python if scripts rely on /usr/bin/python
    ln -s /usr/bin/python3.10 /usr/bin/python && \
    rm -rf /var/lib/apt/lists/*

# Single block for Spark binaries
ARG SPARK_VERSION=3.4.0
RUN wget -qO- https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz \
    | tar -xz -C /opt && \
    mv /opt/spark-${SPARK_VERSION}-bin-hadoop3 ${SPARK_HOME}

# Base OS deps + Python 3.10 needed at runtime for PySpark sessions
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    python3.10 \
    wget curl tini procps zip unzip && \
    rm -rf /var/lib/apt/lists/*

# Spark binaries (using pre-built with Hadoop 3)
ARG SPARK_VERSION=3.4.0
RUN wget -qO- https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz \
    | tar -xz -C /opt && \
    mv /opt/spark-${SPARK_VERSION}-bin-hadoop3 ${SPARK_HOME}

# Livy from builder stage
COPY --from=builder /build/livy/assembly/target/apache-livy-*-bin.zip /tmp/livy.zip
RUN mkdir -p ${LIVY_HOME} && \
    unzip -q /tmp/livy.zip -d /opt && \
    mv /opt/apache-livy-*/* ${LIVY_HOME} && \
    rm /tmp/livy.zip

# minimal configs
RUN mkdir -p ${LIVY_HOME}/conf
RUN echo "export SPARK_HOME=${SPARK_HOME}" >  ${LIVY_HOME}/conf/livy-env.sh && \
    echo "export PYSPARK_PYTHON=${PYSPARK_PYTHON}" >> ${LIVY_HOME}/conf/livy-env.sh && \
    echo "export PYSPARK_DRIVER_PYTHON=${PYSPARK_DRIVER_PYTHON}" >> ${LIVY_HOME}/conf/livy-env.sh && \
    echo 'export LIVY_SERVER_JAVA_OPTS="--add-opens java.base/java.lang.invoke=ALL-UNNAMED --add-opens java.base/java.util.regex=ALL-UNNAMED"' \
    >> ${LIVY_HOME}/conf/livy-env.sh

RUN { \
      echo 'livy.spark.master = local[*]'; \
      echo 'livy.spark.deploy-mode = client'; \
      echo 'livy.server.host = 0.0.0.0'; \
    } > ${LIVY_HOME}/conf/livy.conf

# Add default log4j properties to avoid warnings
RUN echo "log4j.rootCategory=INFO, console" > ${LIVY_HOME}/conf/log4j.properties && \
    echo "log4j.appender.console=org.apache.log4j.ConsoleAppender" >> ${LIVY_HOME}/conf/log4j.properties && \
    echo "log4j.appender.console.target=System.err" >> ${LIVY_HOME}/conf/log4j.properties && \
    echo "log4j.appender.console.layout=org.apache.log4j.PatternLayout" >> ${LIVY_HOME}/conf/log4j.properties && \
    echo "log4j.appender.console.layout.ConversionPattern=%d{yy/MM/dd HH:mm:ss} %p %c{1}: %m%n" >> ${LIVY_HOME}/conf/log4j.properties && \
    # Silence overly verbose logs
    echo "log4j.logger.org.apache.spark=WARN" >> ${LIVY_HOME}/conf/log4j.properties && \
    echo "log4j.logger.org.eclipse.jetty=WARN" >> ${LIVY_HOME}/conf/log4j.properties

EXPOSE 8998
ENTRYPOINT ["/usr/bin/tini", "--"]
# Run Livy server in the foreground
CMD ["/opt/livy/bin/livy-server"]

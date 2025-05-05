##########################
# Stage 1 – build Livy
##########################
FROM maven:3.9.7-eclipse-temurin-17 AS builder

# --- Build‑time parameters -------------
ARG LIVY_GIT=https://github.com/SimpleDataLabsInc/incubator-livy.git
ARG LIVY_BRANCH=ashvjit/apache-master
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

# 1‑a. clone your fork/branch
RUN git clone --depth 1 --single-branch --branch "${LIVY_BRANCH}" \
    "${LIVY_GIT}" livy

# 1‑b. patch Livy’s POM to target Spark 3.4 + Scala 2.12
RUN sed -i \
    -e 's/<scala.binary.version>.*<\/scala.binary.version>/<scala.binary.version>'"${SCALA_BINARY}"'<\/scala.binary.version>/' \
    -e '0,/<spark.version>.*<\/spark.version>/s//<spark.version>'"${SPARK_VERSION}"'<\/spark.version>/' \
    livy/pom.xml

# 1‑c. compile (Spark‑3 profile, skip tests)
RUN mvn -T1C -f livy -Pspark3 -DskipTests -DskipITs -pl '!python-api,!coverage,!examples' -am clean package

##########################
# Stage 2 – runtime
##########################
FROM openjdk:17-jdk-slim

ENV LIVY_HOME=/opt/livy \
    SPARK_HOME=/opt/spark \
    PYTHON_VERSION=3.10.12 \
    PYSPARK_PYTHON=/usr/bin/python3.10 \
    PYSPARK_DRIVER_PYTHON=/usr/bin/python3.10 \
    PATH="/opt/livy/bin:/opt/spark/bin:${PATH}"

# base OS deps
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 wget curl tini procps zip unzip && \
    rm -rf /var/lib/apt/lists/*

# Spark binaries
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
RUN echo 'export SPARK_HOME=/opt/spark' >  ${LIVY_HOME}/conf/livy-env.sh && \
    echo 'export LIVY_SERVER_JAVA_OPTS="--add-opens java.base/java.lang.invoke=ALL-UNNAMED --add-opens java.base/java.util.regex=ALL-UNNAMED"' \
    >> ${LIVY_HOME}/conf/livy-env.sh
RUN { \
      echo 'livy.spark.master = local[*]'; \
      echo 'livy.spark.deploy-mode = client'; \
      echo 'livy.rsc.rpc.server.address = 0.0.0.0'; \
    } > ${LIVY_HOME}/conf/livy.conf

RUN rm -f /opt/livy/repl_2.12-jars/scala-compiler-2.12.15.jar \
          /opt/livy/repl_2.12-jars/scala-reflect-2.12.15.jar

ARG SCALA_VERSION=2.12.17
RUN curl -sSL \
    https://repo1.maven.org/maven2/org/scala-lang/scala-compiler/${SCALA_VERSION}/scala-compiler-${SCALA_VERSION}.jar \
    -o /opt/livy/repl_2.12-jars/scala-compiler-${SCALA_VERSION}.jar \
RUN curl -sSL \
    https://repo1.maven.org/maven2/org/scala-lang/scala-reflect/${SCALA_VERSION}/scala-reflect-${SCALA_VERSION}.jar \
    -o /opt/livy/repl_2.12-jars/scala-reflect-${SCALA_VERSION}.jar

EXPOSE 8998
ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["/opt/livy/bin/livy-server","start"]

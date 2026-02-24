# Livy with standalone Spark Cluster
## Pre-requisite
Following steps use Ubuntu as development environment but most of the instructions can be modified to fit another OS as well.
* Install wsl if on windows, instructions available [here](https://ubuntu.com/tutorials/install-ubuntu-on-wsl2-on-windows-11-with-gui-support)
* Install docker engine, instructions available [here](https://docs.docker.com/engine/install/ubuntu/)
* Install docker-compose, instructions available [here](https://docs.docker.com/compose/install/)

## Standalone cluster using docker-compose

### Option A: Spark 3.x + Scala 2.12 (default)
```
cd dev/docker && ./build-images.sh
```
This clones the repo and builds Livy from source inside the container with Scala 2.12 + Spark 3.2.3.

### Option B: Spark 4.x + Scala 2.13
```
cd dev/docker
SPARK_VERSION=4.0.0 SCALA_VERSION=2.13 HADOOP_VERSION=3.4.1 JAVA_VERSION=17 ./build-images.sh
```
This clones the repo and builds Livy from source inside the container with Scala 2.13 + Spark 4.0.0.

No pre-built Livy ZIP is required -- the Dockerfile clones the repo via `git clone` and runs `mvn package` inside a Docker build stage using `livy-dev-base` (which has JDK + Maven). The final runtime image only contains the built binaries.

### Environment variables for `build-images.sh`
| Variable | Default | Description |
|---|---|---|
| `SPARK_VERSION` | `3.2.3` | Spark version to use |
| `SCALA_VERSION` | `2.12` | Scala binary version (`2.12` or `2.13`) |
| `HADOOP_VERSION` | `3.3.1` | Hadoop version |
| `JAVA_VERSION` | `8` (Spark 3) / `17` (Spark 4) | JDK version, auto-detected from Spark major version |
| `HIVE_VERSION` | `2.3.9` | Hive version |
| `LIVY_VERSION` | `0.10.0-incubating-SNAPSHOT` | Livy version string |
| `LIVY_REPO` | `https://github.com/SimpleDataLabsInc/incubator-livy.git` | Git repo URL to clone |
| `LIVY_BRANCH` | `prophecy-master-refresh` | Git branch to checkout |

### Build architecture
The build uses a 3-layer Docker image approach:
1. **livy-dev-base** -- Ubuntu + JDK + Maven + Python (used as Maven build stage too)
2. **livy-dev-spark** -- Adds Hadoop + Spark on top of base
3. **livy-dev-server** -- Multi-stage: clones the repo + builds Livy from source in stage 1 (using livy-dev-base), copies built ZIP into runtime image (on top of livy-dev-spark)

### Customizing container images
`build-images.sh` downloads Hadoop and Spark tarballs from Apache's repository. Private builds can be copied to respective container directories to build a container image with private artifacts as well.

For quicker iteration, copy the modified jars to specific container directories and update corresponding `Dockerfile` to replace those jars as additional steps inside the image.

`livy-dev-cluster` folder contains conf folder with customizable configurations (environment, .conf and log4j.properties files) that can be updated to suit specific needs. Restart the cluster after making changes (without rebuilding the images).

### Launching the cluster
```
livy/dev/docker/livy-dev-cluster$ docker-compose up
Starting spark-master   ... done
Starting spark-worker-1 ... done
Starting livy           ... done
Attaching to spark-worker-1, spark-master, livy
```
### UIs
* Livy UI at http://localhost:8998/
* Spark Master at spark://master:7077 (http://localhost:8080/).
* Spark Worker at spark://spark-worker-1:8881 (http://localhost:8081/)

### Run spark shell
* Login to spark-master or spark-worker or livy container using docker cli
```
$ docker exec -it spark-master /bin/bash
root@master:/opt/spark# spark-shell
```
### Submit requests to livy using REST apis
Login to livy container directly and submit requests using REST endpoint
```
# Create a new session
curl -s -X POST -d '{"kind": "spark","driverMemory":"512M","executorMemory":"512M"}' -H "Content-Type: application/json" http://localhost:8998/sessions/ | jq

# Check session state
curl -s -X GET -H "Content-Type: application/json" http://localhost:8998/sessions/ | jq -r '.sessions[] | [ .id, .state ] | @tsv'

# Submit the simplest `1+1` statement
curl -s -X POST -d '{"code": "1 + 1"}' -H "Content-Type: application/json" http://localhost:8998/sessions/0/statements | jq

# Check for statement status
curl -s -X GET -H "Content-Type: application/json" http://localhost:8998/sessions/0/statements | jq -r '.statements[] | [ .id,.state,.progress,.output.status,.code ] | @tsv'

# Submit simple spark code
curl -s -X POST -d '{"code": "val data = Array(1,2,3); sc.parallelize(data).count"}' -H "Content-Type: application/json" http://localhost:8998/sessions/0/statements | jq

# Check for statement status
curl -s -X GET -H "Content-Type: application/json" http://localhost:8998/sessions/0/statements | jq -r '.statements[] | [ .id,.state,.progress,.output.status,.code ] | @tsv'

# Submit simple sql code (this setup still doesn't have hive metastore configured)
curl -X POST -d '{"kind": "sql", "code": "show databases"}, ' -H "Content-Type: application/json" http://localhost:8998/sessions/0/statements | jq

# Check for statement status
curl -s -X GET -H "Content-Type: application/json" http://localhost:8998/sessions/0/statements | jq -r '.statements[] | [ .id,.state,.progress,.output.status,.code ] | @tsv'
```
### Debugging Livy/Spark/Hadoop
`livy-dev-cluster` has conf directory for spark-master, spark-worker and livy. Configuration files in those directories can be modified before launching the cluster, for example:
1. `Setting log level` - log4j.properties file can be modified in `livy-dev-cluster` folder to change log level for root logger as well as for specific packages
2. `Testing private changes` - copy private jars into respective container folder, update corresponding Dockerfile to copy/replace those jars into respective paths on the container image and rebuild all the images (Note: livy-dev-server builds on top of livy-dev-spark which builds on top of livy-dev-base)
3. `Remote debugging` - livy-env.sh already has customization to start with remote debugging on 9010. Please follow IDE specific guidance on how to debug remotely connecting to specific JDWP port for the daemon. Instructions for IntelliJ are available [here](https://www.jetbrains.com/help/idea/tutorial-remote-debug.html) and for Eclipse, [here](https://help.eclipse.org/latest/index.jsp?topic=%2Forg.eclipse.jdt.doc.user%2Ftasks%2Ftask-remotejava_launch_config.htm)
### Terminate the cluster
Press `CTRL-C` to terminate
```
spark-worker-1    | 2023-01-27 19:16:47,921 INFO shuffle.ExternalShuffleBlockResolver: Application app-20230127191546-0000 removed, cleanupLocalDirs = true
^CGracefully stopping... (press Ctrl+C again to force)
Stopping spark-worker-1 ... done
Stopping spark-master   ... done
```

## Common Gotchas
1. Use `docker-compose down` to clean up all the resources created for the cluster
2. Login to created images to check the state
```
docker run -it [imageId | imageName] /bin/bash
```
3. Spark 4.x requires Java 17 -- pass `JAVA_VERSION=17` (auto-detected when `SPARK_VERSION` starts with 4)
4. Spark 4.x `ArtifactManager` requires a writable working directory; the Dockerfile and docker-compose.yml set `WORKDIR /tmp` and `working_dir: /tmp` respectively to handle this
5. The first build will take longer since Docker clones the repo and Maven downloads all dependencies inside the container. Subsequent builds leverage Docker layer caching if the branch hasn't changed.
6. To build from a different branch or fork, override `LIVY_REPO` and `LIVY_BRANCH` environment variables.

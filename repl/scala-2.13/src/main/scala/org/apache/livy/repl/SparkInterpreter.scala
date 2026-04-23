/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.livy.repl

import java.io.{BufferedReader, File, OutputStreamWriter, PrintWriter}
import java.net.{URL, URLClassLoader}
import java.nio.file.{Files, Paths}

import scala.tools.nsc.GenericRunnerSettings
import scala.tools.nsc.interpreter.Results
import scala.tools.nsc.interpreter.Results.Result

import org.apache.spark.SparkConf
import org.apache.spark.repl.SparkILoop

/**
 * Scala 2.13 version of SparkInterpreter.
 * Uses SparkILoop with createInterpreter() to properly initialize the
 * Scala 2.13 REPL, which requires a ReplReporter (created internally by ILoop).
 */
class SparkInterpreter(protected override val conf: SparkConf) extends AbstractSparkInterpreter {

  private var sparkILoop: SparkILoop = _
  private var replWriter: PrintWriter = _

  override def start(): Unit = {
    require(sparkILoop == null)

    val rootDir = conf.get("spark.repl.classdir", System.getProperty("java.io.tmpdir"))
    val outputDir = Files.createTempDirectory(Paths.get(rootDir), "spark").toFile
    outputDir.deleteOnExit()
    conf.set("spark.repl.class.outputDir", outputDir.getAbsolutePath)

    val settings = new GenericRunnerSettings(_ => ())
    settings.processArguments(List(
      "-Yrepl-outdir", s"${outputDir.getAbsolutePath}"), true)
    settings.usejavacp.value = true

    replWriter = new PrintWriter(new OutputStreamWriter(outputStream), true)
    sparkILoop = new SparkILoop(
      null.asInstanceOf[BufferedReader], replWriter)

    // The ReplReporter is a lazy val that captures Console.out when first
    // accessed (during the first interpret() call, NOT during createInterpreter).
    // Redirect Console.out for the entire init sequence so the reporter's
    // error writer targets our outputStream.
    scala.Console.withOut(outputStream) {
      sparkILoop.createInterpreter(settings)
      sparkILoop.intp.interpret("()")
    }
    replWriter.flush()
    outputStream.reset()

    // Belt-and-suspenders: use reflection to point the reporter's writer
    // at replWriter in case it captured a different stream.
    fixReporterWriter()

    restoreContextClassLoader {
      var classLoader = Thread.currentThread().getContextClassLoader
      while (classLoader != null) {
        if (classLoader.getClass.getCanonicalName ==
          "org.apache.spark.util.MutableURLClassLoader") {
          val extraJarPath = classLoader.asInstanceOf[URLClassLoader].getURLs()
            .filter { u => u.getProtocol == "file" && new File(u.getPath).isFile }
            .filterNot { u => Paths.get(u.toURI).getFileName.toString.startsWith("livy-") }
            .filterNot { u =>
              Paths.get(u.toURI).getFileName.toString.contains("org.scala-lang_scala-reflect")
            }

          val (prophecyJars, otherJars) = extraJarPath.partition { u =>
            Paths.get(u.toURI).getFileName.toString.contains("prophecy-libs")
          }
          otherJars.foreach { p => debug(s"Adding $p to Scala interpreter's class path...") }
          sparkILoop.intp.addUrlsToClassPath(otherJars: _*)
          if (prophecyJars.nonEmpty) {
            prophecyJars.foreach { p => debug(s"Adding $p to compiler classpath only...") }
            sparkILoop.intp.global.extendCompilerClassPath(prophecyJars: _*)
          }
          classLoader = null
        } else {
          classLoader = classLoader.getParent
        }
      }

      postStart()
    }
  }

  override def close(): Unit = synchronized {
    super.close()

    if (sparkILoop != null) {
      sparkILoop.intp.close()
      sparkILoop = null
    }
  }

  override def addJar(jar: String): Unit = {
    val url = new URL(jar)
    if (jar.contains("prophecy-libs")) {
      // Add to compiler classpath only — not the REPL runtime classloader.
      // The runtime classloader will delegate to the parent MutableURLClassLoader
      // (which already has this JAR), avoiding the child-first ClassCastException
      // on Spark 4 where the REPL and SparkListener load different class copies.
      sparkILoop.intp.global.extendCompilerClassPath(url)
    } else {
      sparkILoop.intp.addUrlsToClassPath(url)
    }
  }

  override protected def isStarted(): Boolean = {
    sparkILoop != null
  }

  override protected def interpret(code: String): Result = {
    val result = sparkILoop.intp.interpret(code)
    replWriter.flush()

    if (result == Results.Error) {
      val captured = outputStream.toString("UTF-8")
      if (captured.trim.isEmpty) {
        val snippet = if (code.length > 300) code.substring(0, 300) + "..." else code
        replWriter.println(s"Compilation failed: $snippet")
        replWriter.flush()
      }
    }

    result
  }

  override protected def valueOfTerm(name: String): Option[Any] = {
    sparkILoop.intp.valueOfTerm(name)
  }

  override protected def bind(name: String,
      tpe: String,
      value: Object,
      modifier: List[String]): Unit = {
    sparkILoop.intp.beQuietDuring {
      sparkILoop.intp.bind(name, tpe, value, modifier)
    }
  }

  private def fixReporterWriter(): Unit = {
    try {
      val reporter = sparkILoop.intp.reporter
      var clazz: Class[_] = reporter.getClass
      var done = false
      while (clazz != null && !done) {
        for (name <- Seq("writer", "out")) {
          if (!done) {
            try {
              val f = clazz.getDeclaredField(name)
              if (classOf[java.io.Writer].isAssignableFrom(f.getType)) {
                f.setAccessible(true)
                f.set(reporter, replWriter)
                done = true
                info(s"Successfully patched reporter writer via field '$name' " +
                  s"on ${clazz.getName}")
              }
            } catch {
              case _: NoSuchFieldException =>
              case e: IllegalAccessException =>
                warn(s"Cannot access field '$name' on ${clazz.getName}: ${e.getMessage}. " +
                  "Compiler error messages may not be captured.")
            }
          }
        }
        clazz = clazz.getSuperclass
      }
      if (!done) {
        warn("Failed to patch reporter writer: no writable Writer field found in " +
          s"${reporter.getClass.getName} hierarchy. " +
          "Compilation errors may produce empty error messages.")
      }
    } catch {
      case e: Exception =>
        warn(s"Failed to patch reporter writer: ${e.getClass.getName}: ${e.getMessage}. " +
          "Compilation errors may produce empty error messages.")
    }
  }
}

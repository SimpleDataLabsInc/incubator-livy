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

import org.scalatest._

import org.apache.livy.LivyBaseUnitTestSuite

/**
 * Adversarial tests for the Scala 2.13 SparkInterpreter.
 * These focus on parseError edge cases and error-handling paths that
 * could break under unusual inputs.
 *
 * From the repo root, via Maven:
 * mvn test -pl repl/scala-2.13 -Pscala-2.13 -Pspark3 \
 *  -Dtest=SparkInterpreter213Spec -DfailIfNoTests=false
 *
 */
class SparkInterpreter213Spec extends FunSpec with Matchers with LivyBaseUnitTestSuite {

  // Create interpreter without SparkConf (null) — only parseError is safe to call
  val interpreter = new SparkInterpreter(null)

  describe("parseError - edge cases") {

    it("should handle empty string") {
      val (ename, traceback) = interpreter.parseError("")
      ename shouldBe "unknown error"
      traceback shouldBe empty
    }

    it("should handle string with only whitespace") {
      val (ename, traceback) = interpreter.parseError("   \t  ")
      ename shouldBe ""
      traceback shouldBe empty
    }

    it("should handle single line with no newline") {
      val (ename, traceback) = interpreter.parseError("some error")
      ename shouldBe "some error"
      traceback shouldBe empty
    }

    it("should handle string that is just newlines") {
      val (ename, traceback) = interpreter.parseError("\n\n\n")
      // KEEP_NEWLINE_REGEX splits on (?<=\n), so "\n\n\n" splits into ["\n", "\n", "\n"]
      ename shouldBe ""
      traceback should have length 2
    }

    it("should handle error with Unicode characters") {
      val error = "error: 変数が見つかりません\n  at line 1\n  at line 2"
      val (ename, traceback) = interpreter.parseError(error)
      ename shouldBe "error: 変数が見つかりません"
      traceback should have length 2
    }

    it("should handle error with very long first line") {
      val longLine = "error: " + "x" * 10000
      val error = longLine + "\n  at somewhere"
      val (ename, traceback) = interpreter.parseError(error)
      ename shouldBe longLine
      traceback should have length 1
    }

    it("should handle error with CRLF line endings") {
      val error = "error: something\r\n  at line 1\r\n  at line 2"
      val (ename, traceback) = interpreter.parseError(error)
      // KEEP_NEWLINE_REGEX only splits on \n, so \r stays in the strings
      ename should startWith("error: something")
    }

    it("should handle error with mixed line endings") {
      val error = "error: mixed\n  unix line\r\n  windows line\n  unix again"
      val (ename, traceback) = interpreter.parseError(error)
      ename shouldBe "error: mixed"
      traceback.length should be >= 3
    }

    it("should handle Scala 2.13 style error with caret pointer") {
      val error =
        """-- [E006] Not Found Error: ---
          |1 |val x: Strin = "hello"
          |  |       ^^^^^
          |  |       Not found: type Strin
          |""".stripMargin
      val (ename, traceback) = interpreter.parseError(error)
      ename shouldBe "-- [E006] Not Found Error: ---"
      traceback.length should be >= 3
    }

    it("should handle nested exception with 'Caused by'") {
      val error =
        """java.lang.RuntimeException: outer
          |  at MyClass.method(MyClass.scala:10)
          |Caused by: java.io.IOException: inner
          |  at MyClass.inner(MyClass.scala:5)
          |  ... 20 more""".stripMargin
      val (ename, traceback) = interpreter.parseError(error)
      ename shouldBe "java.lang.RuntimeException: outer"
      traceback.length should be >= 4
      traceback.exists(_.contains("Caused by")) shouldBe true
    }

    it("should handle error message with null bytes") {
      val error = "error: contains\u0000null\nbyte\u0000here"
      val (ename, traceback) = interpreter.parseError(error)
      ename should include("null")
      traceback should have length 1
    }

    it("should handle compilation failed fallback message format") {
      // This tests the format produced by the interpret() fallback
      val code = "a" * 350
      val snippet = code.substring(0, 300) + "..."
      val error = s"Compilation failed: $snippet"
      val (ename, traceback) = interpreter.parseError(error)
      ename should startWith("Compilation failed:")
      ename.length should be > 300
    }

    it("should handle error with only a trailing newline") {
      val (ename, traceback) = interpreter.parseError("single error\n")
      ename shouldBe "single error"
      traceback should have length 1
      traceback.head shouldBe ""
    }

    it("should handle error with tab-indented traceback") {
      val error = "java.lang.NPE\n\tat Foo.bar(Foo.java:1)\n\tat Baz.qux(Baz.java:2)"
      val (ename, traceback) = interpreter.parseError(error)
      ename shouldBe "java.lang.NPE"
      traceback should have length 2
    }
  }

  describe("KEEP_NEWLINE_REGEX splitting behavior") {

    it("should preserve newlines in split results") {
      val input = "line1\nline2\nline3"
      val parts = AbstractSparkInterpreter.KEEP_NEWLINE_REGEX.split(input)
      parts should have length 3
      parts(0) shouldBe "line1\n"
      parts(1) shouldBe "line2\n"
      parts(2) shouldBe "line3"
    }

    it("should handle input with no newlines") {
      val parts = AbstractSparkInterpreter.KEEP_NEWLINE_REGEX.split("no newlines here")
      parts should have length 1
      parts(0) shouldBe "no newlines here"
    }

    it("should handle consecutive newlines") {
      val parts = AbstractSparkInterpreter.KEEP_NEWLINE_REGEX.split("a\n\nb")
      parts should have length 3
      parts(0) shouldBe "a\n"
      parts(1) shouldBe "\n"
      parts(2) shouldBe "b"
    }
  }
}

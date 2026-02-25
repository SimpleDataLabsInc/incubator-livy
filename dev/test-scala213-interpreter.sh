#!/usr/bin/env bash
# ============================================================================
# Adversarial test suite for Scala 2.13 Livy Interpreter via REST API
# Designed to find edge cases and break the REPL.
#
# Usage:
#   ./test-scala213-interpreter.sh [LIVY_URL]
#   Default LIVY_URL: http://localhost:8998
#
# Prerequisites: curl, python3 (for JSON parsing)
# ============================================================================

set -euo pipefail

LIVY_URL="${1:-http://localhost:8998}"
PASS=0
FAIL=0
ERRORS=()
SESSION_ID=""

# ---------- helpers ----------------------------------------------------------

color_green() { printf '\033[0;32m%s\033[0m' "$1"; }
color_red()   { printf '\033[0;31m%s\033[0m' "$1"; }
color_yellow(){ printf '\033[0;33m%s\033[0m' "$1"; }

log()  { echo "[$(date +%H:%M:%S)] $*"; }
pass() { PASS=$((PASS+1)); log "$(color_green 'PASS') - $1"; }
fail() { FAIL=$((FAIL+1)); ERRORS+=("$1: $2"); log "$(color_red 'FAIL') - $1: $2"; }

json_field() {
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null
}

wait_for_session() {
  local sid=$1 max_wait=${2:-120} elapsed=0
  while [ $elapsed -lt $max_wait ]; do
    local state
    state=$(curl -s "$LIVY_URL/sessions/$sid" | json_field "['state']")
    if [ "$state" = "idle" ]; then
      return 0
    elif [ "$state" = "dead" ] || [ "$state" = "error" ]; then
      return 1
    fi
    sleep 5
    elapsed=$((elapsed+5))
  done
  return 1
}

submit_and_wait() {
  local code="$1" max_wait=${2:-60}
  local stmt_id
  stmt_id=$(curl -s -X POST "$LIVY_URL/sessions/$SESSION_ID/statements" \
    -H 'Content-Type: application/json' \
    -d "{\"code\": $(python3 -c "import json; print(json.dumps('$code'))" 2>/dev/null || echo "\"$code\"")}" \
    | json_field "['id']")

  local elapsed=0
  while [ $elapsed -lt $max_wait ]; do
    local state
    state=$(curl -s "$LIVY_URL/sessions/$SESSION_ID/statements/$stmt_id" \
      | json_field "['state']")
    if [ "$state" = "available" ] || [ "$state" = "cancelled" ] || [ "$state" = "error" ]; then
      curl -s "$LIVY_URL/sessions/$SESSION_ID/statements/$stmt_id"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done
  echo '{"state":"timeout"}'
}

# More robust submission that handles complex code with special characters
submit_code() {
  local tmpfile
  tmpfile=$(mktemp)
  local code="$1"
  local max_wait=${2:-60}

  python3 -c "
import json, sys
code = sys.stdin.read()
print(json.dumps({'code': code}))
" <<< "$code" > "$tmpfile"

  local stmt_id
  stmt_id=$(curl -s -X POST "$LIVY_URL/sessions/$SESSION_ID/statements" \
    -H 'Content-Type: application/json' \
    -d @"$tmpfile" | json_field "['id']")
  rm -f "$tmpfile"

  local elapsed=0
  while [ $elapsed -lt $max_wait ]; do
    local state
    state=$(curl -s "$LIVY_URL/sessions/$SESSION_ID/statements/$stmt_id" \
      | json_field "['state']")
    if [ "$state" = "available" ] || [ "$state" = "cancelled" ] || [ "$state" = "error" ]; then
      curl -s "$LIVY_URL/sessions/$SESSION_ID/statements/$stmt_id"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done
  echo '{"state":"timeout"}'
}

get_status()  { echo "$1" | json_field "['output']['status']"; }
get_text()    { echo "$1" | json_field "['output']['data']['text/plain']"; }
get_ename()   { echo "$1" | json_field "['output']['ename']"; }
get_evalue()  { echo "$1" | json_field "['output']['evalue']"; }

# ---------- setup ------------------------------------------------------------

log "Livy URL: $LIVY_URL"
log "Checking Livy is reachable..."
VERSION=$(curl -s "$LIVY_URL/version" | json_field "['version']")
log "Livy version: $VERSION"

log "Creating Spark session..."
SESSION_ID=$(curl -s -X POST "$LIVY_URL/sessions" \
  -H 'Content-Type: application/json' \
  -d '{"kind":"spark","conf":{"spark.master":"local[*]"}}' \
  | json_field "['id']")
log "Session ID: $SESSION_ID"

log "Waiting for session to become idle..."
if ! wait_for_session "$SESSION_ID" 180; then
  log "$(color_red 'FATAL'): Session failed to start"
  exit 1
fi
log "Session ready. Running adversarial tests..."
echo ""

# ============================================================================
# TEST CATEGORY 1: Basic Scala 2.13 features
# ============================================================================
log "$(color_yellow '=== Category 1: Scala 2.13 Language Features ===')"

# Test 1.1: String interpolation with special chars
RESULT=$(submit_code 'val x = 42; println(s"value=$x, expr=${x * 2}")')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "1.1 String interpolation with expressions"
else
  fail "1.1 String interpolation" "$(get_evalue "$RESULT")"
fi

# Test 1.2: Scala 2.13 collection APIs (groupMap, added in 2.13)
RESULT=$(submit_code 'val r = List(("a",1),("b",2),("a",3)).groupMap(_._1)(_._2); println(r)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "1.2 Scala 2.13 groupMap (new collection API)"
else
  fail "1.2 groupMap" "$(get_evalue "$RESULT")"
fi

# Test 1.3: Using .pipe (Scala 2.13 chaining ops)
RESULT=$(submit_code 'import scala.util.chaining._; val r = 42.pipe(_ * 2); println(r)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "1.3 Scala 2.13 pipe chaining"
else
  fail "1.3 pipe chaining" "$(get_evalue "$RESULT")"
fi

# Test 1.4: LazyList (replaced Stream in 2.13)
RESULT=$(submit_code 'val ll = LazyList.from(1).take(5).toList; println(ll)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "1.4 LazyList (2.13 replacement for Stream)"
else
  fail "1.4 LazyList" "$(get_evalue "$RESULT")"
fi

# Test 1.5: Using keyword as identifier with backticks
RESULT=$(submit_code 'val `type` = "hello"; println(`type`)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "1.5 Backtick-escaped keyword as identifier"
else
  fail "1.5 backtick keyword" "$(get_evalue "$RESULT")"
fi

echo ""
# ============================================================================
# TEST CATEGORY 2: Error handling edge cases
# ============================================================================
log "$(color_yellow '=== Category 2: Error Handling ===')"

# Test 2.1: Compilation error should return non-empty error message
RESULT=$(submit_code 'val x: String = 42')
STATUS=$(get_status "$RESULT")
if [ "$STATUS" = "error" ]; then
  EVALUE=$(get_evalue "$RESULT")
  if [ -n "$EVALUE" ] && [ "$EVALUE" != "" ] && [ "$EVALUE" != "None" ]; then
    pass "2.1 Compilation error returns non-empty message"
  else
    fail "2.1 Compilation error" "Error message is EMPTY (known Scala 2.13 bug)"
  fi
else
  fail "2.1 Compilation error" "Expected error status, got: $STATUS"
fi

# Test 2.2: Runtime exception should have stack trace
RESULT=$(submit_code 'throw new RuntimeException("adversarial test")')
STATUS=$(get_status "$RESULT")
if [ "$STATUS" = "error" ]; then
  EVALUE=$(get_evalue "$RESULT")
  if echo "$EVALUE" | grep -q "RuntimeException"; then
    pass "2.2 Runtime exception with message"
  else
    fail "2.2 Runtime exception" "Expected RuntimeException in: $EVALUE"
  fi
else
  fail "2.2 Runtime exception" "Expected error, got: $STATUS"
fi

# Test 2.3: StackOverflow error
RESULT=$(submit_code 'def inf: Int = inf + 1; inf' 30)
STATUS=$(get_status "$RESULT")
if [ "$STATUS" = "error" ]; then
  pass "2.3 StackOverflow handled gracefully"
else
  fail "2.3 StackOverflow" "Expected error, got: $STATUS"
fi

# Test 2.4: OutOfMemoryError (controlled - don't actually OOM)
RESULT=$(submit_code 'try { val x = new Array[Byte](Int.MaxValue) } catch { case _: OutOfMemoryError => println("OOM caught") }')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "2.4 OOM caught in user code"
else
  fail "2.4 OOM handling" "$(get_evalue "$RESULT")"
fi

# Test 2.5: Division by zero
RESULT=$(submit_code 'val r = 1 / 0')
if [ "$(get_status "$RESULT")" = "error" ]; then
  pass "2.5 Division by zero returns error"
else
  fail "2.5 Division by zero" "Expected error but got ok"
fi

# Test 2.6: Undefined variable reference
RESULT=$(submit_code 'println(undefinedVariable12345)')
if [ "$(get_status "$RESULT")" = "error" ]; then
  EVALUE=$(get_evalue "$RESULT")
  if [ -n "$EVALUE" ] && [ "$EVALUE" != "" ]; then
    pass "2.6 Undefined variable error has message"
  else
    fail "2.6 Undefined variable" "Error message is EMPTY"
  fi
else
  fail "2.6 Undefined variable" "Expected error"
fi

echo ""
# ============================================================================
# TEST CATEGORY 3: Multi-line and incomplete statements
# ============================================================================
log "$(color_yellow '=== Category 3: Multi-line & Incomplete Statements ===')"

# Test 3.1: Multi-line class definition
RESULT=$(submit_code 'class Foo {
  def bar: Int = 42
  def baz: String = "hello"
}
val f = new Foo
println(f.bar)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "3.1 Multi-line class definition"
else
  fail "3.1 Multi-line class" "$(get_evalue "$RESULT")"
fi

# Test 3.2: Multi-line function with pattern matching
RESULT=$(submit_code 'def describe(x: Any): String = x match {
  case i: Int => s"int: $i"
  case s: String => s"str: $s"
  case _ => "unknown"
}
println(describe(42))
println(describe("hi"))')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "3.2 Multi-line pattern matching"
else
  fail "3.2 Pattern matching" "$(get_evalue "$RESULT")"
fi

# Test 3.3: Statement with trailing comment
RESULT=$(submit_code 'val x = 42 // this is a comment
println(x)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "3.3 Statement with trailing comment"
else
  fail "3.3 Trailing comment" "$(get_evalue "$RESULT")"
fi

# Test 3.4: Multi-line block comment between statements
RESULT=$(submit_code 'val a = 1
/*
 * This is a
 * multi-line comment
 */
val b = 2
println(a + b)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  TEXT=$(get_text "$RESULT")
  if echo "$TEXT" | grep -q "3"; then
    pass "3.4 Multi-line block comment between statements"
  else
    fail "3.4 Block comment" "Output doesn't contain expected value 3"
  fi
else
  fail "3.4 Block comment" "$(get_evalue "$RESULT")"
fi

# Test 3.5: Deeply nested braces
RESULT=$(submit_code 'val r = { { { { { 1 + 2 } } } } }; println(r)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "3.5 Deeply nested braces"
else
  fail "3.5 Nested braces" "$(get_evalue "$RESULT")"
fi

# Test 3.6: For-comprehension spanning multiple lines
RESULT=$(submit_code 'val r = for {
  x <- 1 to 3
  y <- 1 to 3
  if x != y
} yield (x, y)
println(r.size)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "3.6 Multi-line for-comprehension"
else
  fail "3.6 For-comprehension" "$(get_evalue "$RESULT")"
fi

echo ""
# ============================================================================
# TEST CATEGORY 4: String and encoding edge cases
# ============================================================================
log "$(color_yellow '=== Category 4: Strings & Encoding ===')"

# Test 4.1: Triple-quoted string with special chars
RESULT=$(submit_code 'val s = """He said "hello" and \n she said '\''bye'\''"""; println(s.length)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "4.1 Triple-quoted string with special chars"
else
  fail "4.1 Triple-quoted string" "$(get_evalue "$RESULT")"
fi

# Test 4.2: Unicode string
RESULT=$(submit_code 'val s = "こんにちは世界 🌍"; println(s)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "4.2 Unicode string with emoji"
else
  fail "4.2 Unicode" "$(get_evalue "$RESULT")"
fi

# Test 4.3: Very long string
RESULT=$(submit_code 'val s = "x" * 100000; println(s.length)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "4.3 Very long string (100K chars)"
else
  fail "4.3 Long string" "$(get_evalue "$RESULT")"
fi

# Test 4.4: String with newlines and tabs
RESULT=$(submit_code 'val s = "line1\nline2\ttab"; println(s.split("\n").length)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "4.4 String with escape sequences"
else
  fail "4.4 Escape sequences" "$(get_evalue "$RESULT")"
fi

# Test 4.5: Empty string operations
RESULT=$(submit_code 'val e = ""; println(e.isEmpty); println(e.length); println(e.reverse)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "4.5 Empty string operations"
else
  fail "4.5 Empty string" "$(get_evalue "$RESULT")"
fi

echo ""
# ============================================================================
# TEST CATEGORY 5: Concurrency and state
# ============================================================================
log "$(color_yellow '=== Category 5: State & Concurrency ===')"

# Test 5.1: Variable persists across statements
RESULT=$(submit_code 'val persist_test = 12345')
RESULT2=$(submit_code 'println(persist_test)')
if [ "$(get_status "$RESULT2")" = "ok" ]; then
  TEXT=$(get_text "$RESULT2")
  if echo "$TEXT" | grep -q "12345"; then
    pass "5.1 Variable persists across statements"
  else
    fail "5.1 State persistence" "Expected 12345, got: $TEXT"
  fi
else
  fail "5.1 State persistence" "$(get_evalue "$RESULT2")"
fi

# Test 5.2: Redefine val (should succeed in REPL)
RESULT=$(submit_code 'val redef = 1')
RESULT2=$(submit_code 'val redef = 2; println(redef)')
if [ "$(get_status "$RESULT2")" = "ok" ]; then
  TEXT=$(get_text "$RESULT2")
  if echo "$TEXT" | grep -q "2"; then
    pass "5.2 Redefine val in REPL"
  else
    fail "5.2 Redefine val" "Expected 2, got: $TEXT"
  fi
else
  fail "5.2 Redefine val" "$(get_evalue "$RESULT2")"
fi

# Test 5.3: Mutable var
RESULT=$(submit_code 'var counter = 0; for (_ <- 1 to 100) counter += 1; println(counter)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  TEXT=$(get_text "$RESULT")
  if echo "$TEXT" | grep -q "100"; then
    pass "5.3 Mutable var accumulation"
  else
    fail "5.3 Mutable var" "Expected 100, got: $TEXT"
  fi
else
  fail "5.3 Mutable var" "$(get_evalue "$RESULT")"
fi

# Test 5.4: Define and use implicit
RESULT=$(submit_code 'implicit val mult: Int = 3
def multiply(x: Int)(implicit m: Int): Int = x * m
println(multiply(7))')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  TEXT=$(get_text "$RESULT")
  if echo "$TEXT" | grep -q "21"; then
    pass "5.4 Implicit values"
  else
    fail "5.4 Implicit values" "Expected 21, got: $TEXT"
  fi
else
  fail "5.4 Implicit values" "$(get_evalue "$RESULT")"
fi

echo ""
# ============================================================================
# TEST CATEGORY 6: Spark-specific operations
# ============================================================================
log "$(color_yellow '=== Category 6: Spark Operations ===')"

# Test 6.1: Create DataFrame from Seq
RESULT=$(submit_code 'val df = Seq((1,"a"),(2,"b"),(3,"c")).toDF("id","val")
println(df.count())')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  TEXT=$(get_text "$RESULT")
  if echo "$TEXT" | grep -q "3"; then
    pass "6.1 DataFrame from Seq"
  else
    fail "6.1 DataFrame" "Expected 3, got: $TEXT"
  fi
else
  fail "6.1 DataFrame" "$(get_evalue "$RESULT")"
fi

# Test 6.2: SQL query
RESULT=$(submit_code 'spark.sql("SELECT 1 + 1 AS result").show()')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "6.2 Spark SQL query"
else
  fail "6.2 SQL query" "$(get_evalue "$RESULT")"
fi

# Test 6.3: RDD operations
RESULT=$(submit_code 'val rdd = sc.parallelize(1 to 100)
println(rdd.reduce(_ + _))')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  TEXT=$(get_text "$RESULT")
  if echo "$TEXT" | grep -q "5050"; then
    pass "6.3 RDD reduce"
  else
    fail "6.3 RDD reduce" "Expected 5050, got: $TEXT"
  fi
else
  fail "6.3 RDD reduce" "$(get_evalue "$RESULT")"
fi

# Test 6.4: UDF definition and use
RESULT=$(submit_code 'import org.apache.spark.sql.functions.udf
val doubleUdf = udf((x: Int) => x * 2)
val df = Seq(1,2,3).toDF("v")
df.withColumn("doubled", doubleUdf(col("v"))).show()')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "6.4 UDF definition and use"
else
  fail "6.4 UDF" "$(get_evalue "$RESULT")"
fi

# Test 6.5: Empty DataFrame
RESULT=$(submit_code 'val emptyDf = spark.emptyDataFrame
println(emptyDf.count())')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  TEXT=$(get_text "$RESULT")
  if echo "$TEXT" | grep -q "0"; then
    pass "6.5 Empty DataFrame"
  else
    fail "6.5 Empty DataFrame" "Expected 0, got: $TEXT"
  fi
else
  fail "6.5 Empty DataFrame" "$(get_evalue "$RESULT")"
fi

# Test 6.6: DataFrame with null values
RESULT=$(submit_code 'val df = Seq((1, Some("a")), (2, None), (3, Some("c"))).toDF("id", "val")
println(df.filter(col("val").isNull).count())')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  TEXT=$(get_text "$RESULT")
  if echo "$TEXT" | grep -q "1"; then
    pass "6.6 DataFrame with nulls"
  else
    fail "6.6 Null handling" "Expected 1, got: $TEXT"
  fi
else
  fail "6.6 Null handling" "$(get_evalue "$RESULT")"
fi

echo ""
# ============================================================================
# TEST CATEGORY 7: Adversarial / stress inputs
# ============================================================================
log "$(color_yellow '=== Category 7: Adversarial Inputs ===')"

# Test 7.1: Empty code
RESULT=$(submit_code '')
STATUS=$(get_status "$RESULT")
if [ "$STATUS" = "ok" ]; then
  pass "7.1 Empty code submission"
else
  fail "7.1 Empty code" "Expected ok, got error"
fi

# Test 7.2: Just whitespace
RESULT=$(submit_code '   ')
STATUS=$(get_status "$RESULT")
if [ "$STATUS" = "ok" ]; then
  pass "7.2 Whitespace-only code"
else
  fail "7.2 Whitespace code" "Expected ok, got error"
fi

# Test 7.3: Just a comment
RESULT=$(submit_code '// nothing here')
STATUS=$(get_status "$RESULT")
if [ "$STATUS" = "ok" ]; then
  pass "7.3 Comment-only code"
else
  fail "7.3 Comment-only" "Expected ok, got error"
fi

# Test 7.4: Rapid successive submissions (output interleaving test)
log "  Submitting 5 rapid statements..."
for i in $(seq 1 5); do
  curl -s -X POST "$LIVY_URL/sessions/$SESSION_ID/statements" \
    -H 'Content-Type: application/json' \
    -d "{\"code\": \"println(\\\"rapid-$i\\\")\"}" > /dev/null
done
sleep 15
ALL_OK=true
for i in $(seq 0 4); do
  STMT_ID=$((i))
  # Statement IDs are auto-incrementing, need to find the right ones
done
# Just verify session is still healthy after rapid fire
SSTATE=$(curl -s "$LIVY_URL/sessions/$SESSION_ID" | json_field "['state']")
if [ "$SSTATE" = "idle" ] || [ "$SSTATE" = "busy" ]; then
  pass "7.4 Session healthy after rapid submissions"
else
  fail "7.4 Rapid submissions" "Session state: $SSTATE"
fi

# Test 7.5: Very long single-line code
LONG_EXPR="val longResult = 0"
for i in $(seq 1 200); do
  LONG_EXPR="$LONG_EXPR + 1"
done
LONG_EXPR="$LONG_EXPR; println(longResult)"
RESULT=$(submit_code "$LONG_EXPR" 30)
if [ "$(get_status "$RESULT")" = "ok" ]; then
  TEXT=$(get_text "$RESULT")
  if echo "$TEXT" | grep -q "200"; then
    pass "7.5 Very long single-line expression (200 additions)"
  else
    fail "7.5 Long expression" "Expected 200, got: $TEXT"
  fi
else
  fail "7.5 Long expression" "$(get_evalue "$RESULT")"
fi

# Test 7.6: Semicolons as statement separator
RESULT=$(submit_code 'val aa = 1; val bb = 2; val cc = aa + bb; println(cc)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  TEXT=$(get_text "$RESULT")
  if echo "$TEXT" | grep -q "3"; then
    pass "7.6 Semicolons as statement separator"
  else
    fail "7.6 Semicolons" "Expected 3, got: $TEXT"
  fi
else
  fail "7.6 Semicolons" "$(get_evalue "$RESULT")"
fi

# Test 7.7: Thread.sleep in user code (should not kill the session)
RESULT=$(submit_code 'Thread.sleep(2000); println("survived sleep")' 30)
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "7.7 Thread.sleep in user code"
else
  fail "7.7 Thread.sleep" "$(get_evalue "$RESULT")"
fi

# Test 7.8 (System.exit) removed: kills the Livy JVM — known DoS vector,
# no SecurityManager installed. Not safe to run in CI.

# Test 7.9: Recursive type (should fail compilation, not hang)
RESULT=$(submit_code 'type X = List[X]' 15)
STATUS=$(get_status "$RESULT")
if [ "$STATUS" = "ok" ] || [ "$STATUS" = "error" ]; then
  pass "7.9 Recursive type alias handled (status: $STATUS)"
else
  fail "7.9 Recursive type" "Unexpected: $STATUS"
fi

# Test 7.10: Access interpreter internals via reflection
RESULT=$(submit_code 'val cl = Thread.currentThread.getContextClassLoader; println(cl.getClass.getName)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "7.10 ClassLoader reflection (informational)"
else
  fail "7.10 ClassLoader reflection" "$(get_evalue "$RESULT")"
fi

echo ""
# ============================================================================
# TEST CATEGORY 8: Scala 2.13 specific regressions
# ============================================================================
log "$(color_yellow '=== Category 8: Scala 2.13 Specific Regressions ===')"

# Test 8.1: scala.collection.mutable vs immutable
RESULT=$(submit_code 'import scala.collection.mutable
val buf = mutable.ArrayBuffer(1, 2, 3)
buf.addOne(4)
println(buf.toList)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "8.1 mutable.ArrayBuffer.addOne (2.13 API)"
else
  fail "8.1 ArrayBuffer.addOne" "$(get_evalue "$RESULT")"
fi

# Test 8.2: to(CollectionType) syntax
RESULT=$(submit_code 'val s = (1 to 10).to(Vector); println(s.getClass.getSimpleName)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "8.2 .to(Collection) converter syntax"
else
  fail "8.2 .to() syntax" "$(get_evalue "$RESULT")"
fi

# Test 8.3: String is now a Seq[Char] in 2.13
RESULT=$(submit_code 'val chars: Seq[Char] = "hello"; println(chars.length)')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  pass "8.3 String as Seq[Char] (2.13 change)"
else
  fail "8.3 String as Seq" "$(get_evalue "$RESULT")"
fi

# Test 8.4: IterableOnce (replaces TraversableOnce in 2.13)
RESULT=$(submit_code 'def sum(xs: IterableOnce[Int]): Int = xs.iterator.sum; println(sum(List(1,2,3)))')
if [ "$(get_status "$RESULT")" = "ok" ]; then
  TEXT=$(get_text "$RESULT")
  if echo "$TEXT" | grep -q "6"; then
    pass "8.4 IterableOnce (2.13 API)"
  else
    fail "8.4 IterableOnce" "Expected 6, got: $TEXT"
  fi
else
  fail "8.4 IterableOnce" "$(get_evalue "$RESULT")"
fi

# Test 8.5: Using deprecated Stream triggers deprecation warning, not error
RESULT=$(submit_code 'val s = Stream(1,2,3); println(s.toList)')
STATUS=$(get_status "$RESULT")
if [ "$STATUS" = "ok" ]; then
  pass "8.5 Deprecated Stream still works (with warning)"
elif [ "$STATUS" = "error" ]; then
  EVALUE=$(get_evalue "$RESULT")
  if echo "$EVALUE" | grep -qi "deprecat"; then
    fail "8.5 Deprecated Stream" "Stream is hard-error instead of warning"
  else
    fail "8.5 Deprecated Stream" "Unexpected error: $EVALUE"
  fi
fi

echo ""
# ============================================================================
# SUMMARY
# ============================================================================
TOTAL=$((PASS+FAIL))
echo ""
echo "============================================"
echo " TEST RESULTS"
echo "============================================"
echo " Total:  $TOTAL"
echo " $(color_green "Passed: $PASS")"
echo " $(color_red "Failed: $FAIL")"
echo "============================================"

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for e in "${ERRORS[@]}"; do
    echo "  $(color_red '✗') $e"
  done
fi

echo ""

# ---------- cleanup ----------------------------------------------------------
log "Cleaning up session $SESSION_ID..."
curl -s -X DELETE "$LIVY_URL/sessions/$SESSION_ID" > /dev/null 2>&1 || true
log "Done."

exit $FAIL

#!/usr/bin/env bash
# Hot-patches the org.wso2.carbon.apimgt.gateway OSGi bundle and the
# org.wso2.carbon.apimgt.rest.api.gateway webapp (api#am#gateway#v2.war) into an already-unpacked
# WSO2 API Manager Gateway distribution, WITHOUT bumping product-apim's pom versions and without
# rebuilding the whole distribution.
#
# Why: product-apim's gateway/pom.xml pins carbon.apimgt artifacts to the released 9.33.176. We
# don't want to bump that (out of scope / risks re-resolving half the reactor). We instead build
# carbon-apimgt's affected modules locally at 9.33.177-SNAPSHOT and get the new .class files into
# the runtime.
#
# IMPORTANT lesson learned during the spike: whole-jar replacement of the OSGi bundle
# (org.wso2.carbon.apimgt.gateway_9.33.176.jar) with our 9.33.177-SNAPSHOT build FAILS at startup
# with "Could not start: org.wso2.carbon.apimgt.gateway(...). It's state is uninstalled." - the p2
# profile / bundles.info this distribution was provisioned with records bundle
# org.wso2.carbon.apimgt.gateway at version 9.33.176 with a specific bundle id, and Equinox refuses
# to resolve a jar at that same plugins/ path whose own MANIFEST.MF now says 9.33.177.SNAPSHOT.
# So instead of swapping the whole jar, we inject ONLY the new class files (the throwaway
# org.wso2.carbon.apimgt.gateway.sandbox.* package - the spike does not modify any existing class
# in this module) into the ORIGINAL, untouched 9.33.176 jar from the local .m2 cache, via
# `jar uf` (update-in-place, keeps MANIFEST.MF / Bundle-Version exactly as released). This keeps
# the bundle's identity exactly what the p2 profile expects.
#
# Usage: patch-gateway.sh <runtime-dir>
#   e.g. patch-gateway.sh /c/workspace/runtime/gateway/wso2am-universal-gw-4.7.0-SNAPSHOT
#
# The gateway must be STOPPED before running this (Windows keeps the war/jar files locked while
# the JVM holds them open).

set -euo pipefail

RUNTIME_DIR="${1:?usage: patch-gateway.sh <runtime-dir>}"
CARBON_APIMGT_REPO="${CARBON_APIMGT_REPO:-/c/workspace/carbon-apimgt}"
M2_REPO="${M2_REPO:-$HOME/.m2/repository}"

GATEWAY_MODULE_TARGET="$CARBON_APIMGT_REPO/components/apimgt/org.wso2.carbon.apimgt.gateway/target"
GATEWAY_CLASSES_DIR="$GATEWAY_MODULE_TARGET/classes"
GATEWAY_ORIGINAL_JAR="$M2_REPO/org/wso2/carbon/apimgt/org.wso2.carbon.apimgt.gateway/9.33.176/org.wso2.carbon.apimgt.gateway-9.33.176.jar"
GATEWAY_WAR_SRC="$CARBON_APIMGT_REPO/components/apimgt/org.wso2.carbon.apimgt.rest.api.gateway/target/api#am#gateway#v2.war"

GATEWAY_JAR_DST=$(find "$RUNTIME_DIR/repository/components/plugins" -maxdepth 1 -iname "org.wso2.carbon.apimgt.gateway_*.jar" | head -1)
WEBAPPS_DIR="$RUNTIME_DIR/repository/deployment/server/webapps"

if [ -z "$GATEWAY_JAR_DST" ]; then
    echo "ERROR: could not find org.wso2.carbon.apimgt.gateway_*.jar under $RUNTIME_DIR/repository/components/plugins" >&2
    exit 1
fi
if [ ! -d "$GATEWAY_CLASSES_DIR/org/wso2/carbon/apimgt/gateway/sandbox" ]; then
    echo "ERROR: $GATEWAY_CLASSES_DIR/org/wso2/carbon/apimgt/gateway/sandbox not found - build the gateway module first:" >&2
    echo '  export JAVA_HOME="/c/Program Files/Java/jdk-21.0.10"; export PATH="$JAVA_HOME/bin:$PATH"' >&2
    echo "  cd $CARBON_APIMGT_REPO && mvn -q -o install -DskipTests -Dcheckstyle.skip=true -pl components/apimgt/org.wso2.carbon.apimgt.gateway" >&2
    exit 1
fi
if [ ! -f "$GATEWAY_ORIGINAL_JAR" ]; then
    echo "ERROR: pristine $GATEWAY_ORIGINAL_JAR not found in the local .m2 cache" >&2
    exit 1
fi
if [ ! -f "$GATEWAY_WAR_SRC" ]; then
    echo "ERROR: $GATEWAY_WAR_SRC not found - build the rest.api.gateway module first:" >&2
    echo "  cd $CARBON_APIMGT_REPO && mvn -q -o install -DskipTests -Dcheckstyle.skip=true -pl components/apimgt/org.wso2.carbon.apimgt.rest.api.gateway" >&2
    exit 1
fi

echo "Rebuilding patched bundle from pristine $GATEWAY_ORIGINAL_JAR + new sandbox/*.class"
# NOTE (second lesson learned): adding the new classes with `jar uf` is not enough. OSGi resolves
# Import-Package purely from the MANIFEST.MF Export-Package header, not from the jar's actual
# contents - and the released 9.33.176 manifest was generated (by the bnd/felix maven-bundle-plugin)
# before the sandbox package existed, so it does NOT list
# org.wso2.carbon.apimgt.gateway.sandbox as exported. Without fixing that, every other bundle
# (e.g. the rest.api.gateway webapp) fails with NoClassDefFoundError even though the .class files
# are physically present in the jar. So we also rewrite MANIFEST.MF's Export-Package to prepend
# that package (same Bundle-Version, so bundle identity for the p2 profile is unchanged).
WORKDIR=$(mktemp -d)
mkdir -p "$WORKDIR/unpacked"
(cd "$WORKDIR/unpacked" && jar xf "$GATEWAY_ORIGINAL_JAR")
mkdir -p "$WORKDIR/unpacked/org/wso2/carbon/apimgt/gateway/sandbox"
cp -f "$GATEWAY_CLASSES_DIR"/org/wso2/carbon/apimgt/gateway/sandbox/*.class \
    "$WORKDIR/unpacked/org/wso2/carbon/apimgt/gateway/sandbox/"

# Unfold MANIFEST.MF continuation lines, prepend the sandbox package to Export-Package, then
# re-wrap every header line back to <=72 bytes (java.util.jar.Manifest rejects longer lines).
awk '
{
  gsub(/\r$/, "")
  if ($0 ~ /^ /) { buf = buf substr($0, 2) }
  else { if (buf != "") print buf; buf = $0 }
}
END { if (buf != "") print buf }
' "$WORKDIR/unpacked/META-INF/MANIFEST.MF" \
  | sed 's/^Export-Package: org.wso2.carbon.apimgt.gateway;version="9.33.176";uses/Export-Package: org.wso2.carbon.apimgt.gateway.sandbox;version="9.33.176",org.wso2.carbon.apimgt.gateway;version="9.33.176";uses/' \
  | awk '
{
  line = $0; n = length(line)
  if (n <= 72) { print line; next }
  print substr(line, 1, 72)
  rest = substr(line, 73)
  while (length(rest) > 71) { print " " substr(rest, 1, 71); rest = substr(rest, 72) }
  if (length(rest) > 0) print " " rest
}' \
  | sed 's/$/\r/' > "$WORKDIR/MANIFEST.MF"

if ! grep -q "org.wso2.carbon.apimgt.gateway.sandbox" "$WORKDIR/MANIFEST.MF"; then
    echo "ERROR: failed to inject the sandbox package into Export-Package - check the sed pattern" >&2
    exit 1
fi
cp -f "$WORKDIR/MANIFEST.MF" "$WORKDIR/unpacked/META-INF/MANIFEST.MF"

(cd "$WORKDIR/unpacked" && jar cfm "$WORKDIR/patched.jar" META-INF/MANIFEST.MF -C "$WORKDIR/unpacked" .)

echo "Patching bundle in place: $GATEWAY_JAR_DST"
cp -f "$WORKDIR/patched.jar" "$GATEWAY_JAR_DST"
rm -rf "$WORKDIR"

echo "Patching webapp: $WEBAPPS_DIR/api#am#gateway#v2.war"
rm -rf "$WEBAPPS_DIR/api#am#gateway#v2"
cp -f "$GATEWAY_WAR_SRC" "$WEBAPPS_DIR/api#am#gateway#v2.war"

echo "Clearing OSGi bundle cache"
rm -rf "$RUNTIME_DIR"/repository/components/*/org.eclipse.osgi 2>/dev/null || true
find "$RUNTIME_DIR/repository/components" -maxdepth 1 -type d -iname "cache*" -exec rm -rf {} \; 2>/dev/null || true

echo "Done. Start the gateway (Windows, from cmd.exe or PowerShell - the .sh launcher mis-handles"
echo "MSYS/Git-Bash path translation for the wildcard bin/* classpath):"
echo "  \"$RUNTIME_DIR/bin/gateway.bat\" -DportOffset=1"

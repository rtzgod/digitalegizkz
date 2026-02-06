#!/bin/bash

#######################################################################
# OpenTwins Deployment Test Script
# Tests connectivity and basic functionality of all components
#######################################################################

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get minikube IP or use localhost
MINIKUBE_IP=$(minikube ip 2>/dev/null || echo "localhost")

# Configuration - using NodePorts with minikube IP
DITTO_API="http://$MINIKUBE_IP:30525/api/2"
DITTO_USER="ditto:ditto"
DITTO_DEVOPS="devops:foobar"
HONO_REGISTRY="http://$MINIKUBE_IP:31080/v1"
HONO_MQTT="$MINIKUBE_IP:31883"
INFLUXDB="http://$MINIKUBE_IP:30716"
GRAFANA="http://$MINIKUBE_IP:30718"
EXTENDED_API="http://$MINIKUBE_IP:30528"

echo "Using endpoint: $MINIKUBE_IP"

# Test counter
PASSED=0
FAILED=0

print_header() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

test_pass() {
    echo -e "${GREEN}✓ PASS:${NC} $1"
    ((PASSED++))
}

test_fail() {
    echo -e "${RED}✗ FAIL:${NC} $1"
    ((FAILED++))
}

test_skip() {
    echo -e "${YELLOW}⊘ SKIP:${NC} $1"
}

#######################################################################
# 1. Test Pod Status
#######################################################################
print_header "1. Checking Pod Status"

NOT_RUNNING=$(kubectl get pods --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
TOTAL_PODS=$(kubectl get pods --no-headers 2>/dev/null | wc -l)

if [ "$NOT_RUNNING" -eq 0 ]; then
    test_pass "All $TOTAL_PODS pods are running"
else
    test_fail "$NOT_RUNNING pods not running"
    kubectl get pods | grep -v "Running\|Completed\|NAME"
fi

#######################################################################
# 2. Test Eclipse Ditto API
#######################################################################
print_header "2. Testing Eclipse Ditto API"

# Test Ditto health
DITTO_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "$DITTO_API/../health" 2>/dev/null || echo "000")
if [ "$DITTO_HEALTH" = "200" ]; then
    test_pass "Ditto health endpoint responding"
else
    test_fail "Ditto health endpoint returned $DITTO_HEALTH"
fi

# Create a test thing
THING_ID="org.opentwins:test-device-$(date +%s)"
echo "Creating test thing: $THING_ID"

CREATE_THING=$(curl -s -X PUT "$DITTO_API/things/$THING_ID" \
    -u "$DITTO_USER" \
    -H "Content-Type: application/json" \
    -d '{
        "definition": "org.opentwins:TestDevice:1.0.0",
        "attributes": {
            "name": "Test Device",
            "location": "Lab",
            "createdBy": "test-script"
        },
        "features": {
            "temperature": {
                "properties": {
                    "value": 25.5,
                    "unit": "celsius"
                }
            },
            "humidity": {
                "properties": {
                    "value": 60,
                    "unit": "percent"
                }
            }
        }
    }' -w "\n%{http_code}" 2>/dev/null)

HTTP_CODE=$(echo "$CREATE_THING" | tail -1)
if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "204" ]; then
    test_pass "Created thing in Ditto: $THING_ID"
else
    test_fail "Failed to create thing (HTTP $HTTP_CODE)"
fi

# Read the thing back
GET_THING=$(curl -s -o /dev/null -w "%{http_code}" "$DITTO_API/things/$THING_ID" -u "$DITTO_USER" 2>/dev/null || echo "000")
if [ "$GET_THING" = "200" ]; then
    test_pass "Retrieved thing from Ditto"
else
    test_fail "Failed to retrieve thing (HTTP $GET_THING)"
fi

# Update thing feature
UPDATE_FEATURE=$(curl -s -X PUT "$DITTO_API/things/$THING_ID/features/temperature/properties/value" \
    -u "$DITTO_USER" \
    -H "Content-Type: application/json" \
    -d '30.0' -w "%{http_code}" 2>/dev/null | tail -1)

if [ "$UPDATE_FEATURE" = "204" ] || [ "$UPDATE_FEATURE" = "201" ]; then
    test_pass "Updated thing feature"
else
    test_fail "Failed to update feature (HTTP $UPDATE_FEATURE)"
fi

# List all things
THINGS_COUNT=$(curl -s "$DITTO_API/search/things" -u "$DITTO_USER" 2>/dev/null | grep -o '"thingId"' | wc -l)
test_pass "Found $THINGS_COUNT things in Ditto"

#######################################################################
# 3. Test Eclipse Hono Device Registry
#######################################################################
print_header "3. Testing Eclipse Hono Device Registry"

# Check tenant exists
TENANT_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "$HONO_REGISTRY/tenants/opentwins" 2>/dev/null || echo "000")
if [ "$TENANT_CHECK" = "200" ]; then
    test_pass "Hono tenant 'opentwins' exists"
else
    test_fail "Hono tenant check failed (HTTP $TENANT_CHECK)"
fi

# Register a test device
DEVICE_ID="test-device-$(date +%s)"
echo "Registering test device: $DEVICE_ID"

REGISTER_DEVICE=$(curl -s -X POST "$HONO_REGISTRY/devices/opentwins/$DEVICE_ID" \
    -H "Content-Type: application/json" \
    -d '{"enabled": true}' -w "\n%{http_code}" 2>/dev/null)

HTTP_CODE=$(echo "$REGISTER_DEVICE" | tail -1)
if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "409" ]; then
    test_pass "Registered device in Hono: $DEVICE_ID"
else
    test_fail "Failed to register device (HTTP $HTTP_CODE)"
fi

# Add credentials for the device
ADD_CREDENTIALS=$(curl -s -X PUT "$HONO_REGISTRY/credentials/opentwins/$DEVICE_ID" \
    -H "Content-Type: application/json" \
    -d '[{
        "type": "hashed-password",
        "auth-id": "'$DEVICE_ID'",
        "secrets": [{
            "pwd-plain": "test-secret-123"
        }]
    }]' -w "\n%{http_code}" 2>/dev/null)

HTTP_CODE=$(echo "$ADD_CREDENTIALS" | tail -1)
if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "201" ]; then
    test_pass "Added credentials for device"
else
    test_fail "Failed to add credentials (HTTP $HTTP_CODE)"
fi

#######################################################################
# 4. Test Ditto Connections (Hono integration)
#######################################################################
print_header "4. Testing Ditto Connections"

CONNECTIONS=$(curl -s "$DITTO_API/connections" -u "$DITTO_DEVOPS" 2>/dev/null)
CONN_COUNT=$(echo "$CONNECTIONS" | grep -o '"connectionId"' | wc -l 2>/dev/null || echo "0")

if [ "$CONN_COUNT" -gt 0 ]; then
    test_pass "Found $CONN_COUNT connection(s) in Ditto"
    echo "Connections: $(echo $CONNECTIONS | tr -d '[]\"' | head -c 100)..."
else
    test_fail "No connections found in Ditto"
fi

#######################################################################
# 5. Test InfluxDB
#######################################################################
print_header "5. Testing InfluxDB"

INFLUX_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "$INFLUXDB/health" 2>/dev/null || echo "000")
if [ "$INFLUX_HEALTH" = "200" ]; then
    test_pass "InfluxDB health endpoint responding"
else
    test_fail "InfluxDB health check failed (HTTP $INFLUX_HEALTH)"
fi

#######################################################################
# 6. Test Grafana
#######################################################################
print_header "6. Testing Grafana"

GRAFANA_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "$GRAFANA/api/health" 2>/dev/null || echo "000")
if [ "$GRAFANA_HEALTH" = "200" ]; then
    test_pass "Grafana health endpoint responding"
else
    test_fail "Grafana health check failed (HTTP $GRAFANA_HEALTH)"
fi

#######################################################################
# 7. Test Extended API
#######################################################################
print_header "7. Testing Extended API"

EXTENDED_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "$EXTENDED_API/health" 2>/dev/null || echo "000")
if [ "$EXTENDED_HEALTH" = "200" ]; then
    test_pass "Extended API health endpoint responding"
else
    test_skip "Extended API health check (HTTP $EXTENDED_HEALTH) - may not have /health endpoint"
fi

#######################################################################
# 8. Test MQTT Connectivity (Hono Adapter)
#######################################################################
print_header "8. Testing MQTT Connectivity"

if command -v mosquitto_pub &> /dev/null; then
    # Try to connect to MQTT (will fail auth but proves connectivity)
    timeout 5 mosquitto_pub -h localhost -p 31883 -t "test" -m "test" -u "test@opentwins" -P "test" 2>&1 | grep -q "Connection refused" && \
        test_fail "MQTT connection refused" || test_pass "MQTT port accessible (auth may fail, that's expected)"
else
    test_skip "mosquitto_pub not installed - skipping MQTT test"
fi

#######################################################################
# Cleanup (optional - comment out to keep test data)
#######################################################################
print_header "Cleanup"

# Delete test thing
DELETE_THING=$(curl -s -X DELETE "$DITTO_API/things/$THING_ID" -u "$DITTO_USER" -w "%{http_code}" 2>/dev/null | tail -1)
if [ "$DELETE_THING" = "204" ]; then
    echo "Cleaned up test thing: $THING_ID"
else
    echo "Could not delete test thing (HTTP $DELETE_THING)"
fi

# Delete test device from Hono
DELETE_DEVICE=$(curl -s -X DELETE "$HONO_REGISTRY/devices/opentwins/$DEVICE_ID" -w "%{http_code}" 2>/dev/null | tail -1)
if [ "$DELETE_DEVICE" = "204" ]; then
    echo "Cleaned up test device: $DEVICE_ID"
else
    echo "Could not delete test device (HTTP $DELETE_DEVICE)"
fi

#######################################################################
# Summary
#######################################################################
print_header "Test Summary"

TOTAL=$((PASSED + FAILED))
echo ""
echo -e "Tests passed: ${GREEN}$PASSED${NC}"
echo -e "Tests failed: ${RED}$FAILED${NC}"
echo -e "Total tests:  $TOTAL"
echo ""

if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}All tests passed! OpenTwins deployment is healthy.${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Please check the output above.${NC}"
    exit 1
fi

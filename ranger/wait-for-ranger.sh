#!/bin/bash
# Wait for Ranger Admin to be ready before running service creation scripts
# 
# This script checks if Ranger Admin process is running and port 6080 is listening
# Note: curl is not available in the container, so we use process and port checks

MAX_RETRIES=60
RETRY_INTERVAL=5

echo "Waiting for Ranger Admin to be ready..."

for i in $(seq 1 $MAX_RETRIES); do
  # Check 1: Process is running
  PROCESS_OK=false
  if ps -ef | grep -v grep | grep -q "org.apache.ranger.server.tomcat.EmbeddedServer"; then
    PROCESS_OK=true
  fi
  
  # Check 2: Port 6080 is listening (using bash TCP redirection)
  PORT_OK=false
  if command -v nc >/dev/null 2>&1; then
    # Use nc if available
    if nc -z localhost 6080 >/dev/null 2>&1; then
      PORT_OK=true
    fi
  else
    # Fallback: use bash TCP redirection (timeout 1 second)
    if timeout 1 bash -c "echo > /dev/tcp/localhost/6080" 2>/dev/null; then
      PORT_OK=true
    fi
  fi
  
  # Both checks must pass
  if [ "$PROCESS_OK" = true ] && [ "$PORT_OK" = true ]; then
    echo "Ranger Admin is ready! (Process: OK, Port 6080: listening)"
    exit 0
  fi
  
  # Provide detailed status
  STATUS_PARTS=()
  [ "$PROCESS_OK" = true ] && STATUS_PARTS+=("Process: OK") || STATUS_PARTS+=("Process: waiting")
  [ "$PORT_OK" = true ] && STATUS_PARTS+=("Port 6080: OK") || STATUS_PARTS+=("Port 6080: waiting")
  
  echo "Attempt $i/$MAX_RETRIES: $(IFS=', '; echo "${STATUS_PARTS[*]}") - waiting ${RETRY_INTERVAL}s..."
  sleep $RETRY_INTERVAL
done

echo "ERROR: Ranger Admin did not become ready after $((MAX_RETRIES * RETRY_INTERVAL)) seconds"
echo "Final status check:"
if ps -ef | grep -v grep | grep -q "org.apache.ranger.server.tomcat.EmbeddedServer"; then
  echo "  Process: Running"
else
  echo "  Process: Not running"
fi

if command -v nc >/dev/null 2>&1; then
  if nc -z localhost 6080 >/dev/null 2>&1; then
    echo "  Port 6080: Listening"
  else
    echo "  Port 6080: Not listening"
  fi
else
  if timeout 1 bash -c "echo > /dev/tcp/localhost/6080" 2>/dev/null; then
    echo "  Port 6080: Listening"
  else
    echo "  Port 6080: Not listening"
  fi
fi
exit 1


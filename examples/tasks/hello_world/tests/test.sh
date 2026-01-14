#!/bin/bash
# Test script for hello_world task
# Verifies that hello.txt exists and contains "Hello, World!"

set -euo pipefail

if [ ! -f "hello.txt" ]; then
    echo "FAIL: hello.txt not found"
    echo "0" > reward.txt
    exit 1
fi

CONTENT=$(cat hello.txt)
EXPECTED="Hello, World!"

if [ "$CONTENT" = "$EXPECTED" ]; then
    echo "PASS: hello.txt contains correct content"
    echo "1" > reward.txt
    exit 0
else
    echo "FAIL: hello.txt contains: '$CONTENT'"
    echo "Expected: '$EXPECTED'"
    echo "0" > reward.txt
    exit 1
fi

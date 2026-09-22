#!/bin/sh

redis-stack-server &
REDIS_PID=$!

echo "Waiting for Redis..."

until redis-cli ping >/dev/null 2>&1; do
    sleep 1
done

echo "Redis is ready"

redis-cli BF.RESERVE crawler:urls 0.001 10000000 || true

echo "Bloom filter initialized"

wait $REDIS_PID
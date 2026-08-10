#!/usr/bin/env python3
"""
Example: logical (type-aware) key migration between two TLS-enabled Redis
Clusters, e.g. when moving from a hand-rolled StatefulSet to an
operator-managed RedisCluster, or between major Redis versions where
DUMP/RESTORE payloads aren't cross-compatible.

This is a reference implementation, not a turnkey script — fill in your own
source/destination startup nodes below. Run it from a pod inside the
cluster with the client TLS secret mounted at /tls (ca.crt, tls.crt,
tls.key).

Required environment variables:
    SRC_REDIS_PASSWORD   password for the source cluster
    DST_REDIS_PASSWORD   password for the destination cluster
"""

import os

from redis.cluster import RedisCluster, ClusterNode
from redis.exceptions import ResponseError

TLS = dict(
    ssl=True,
    ssl_ca_certs="/tls/ca.crt",
    ssl_certfile="/tls/tls.crt",
    ssl_keyfile="/tls/tls.key",
)

SRC_PASS = os.environ.get("SRC_REDIS_PASSWORD", "")
DST_PASS = os.environ.get("DST_REDIS_PASSWORD", "")

# Replace these with your own source/destination cluster nodes.
SRC_STARTUP_NODES = [
    ClusterNode("redis-src-0.redis-src-headless.<namespace>.svc.cluster.local", 6379),
    ClusterNode("redis-src-1.redis-src-headless.<namespace>.svc.cluster.local", 6379),
    ClusterNode("redis-src-2.redis-src-headless.<namespace>.svc.cluster.local", 6379),
]
DST_STARTUP_NODES = [
    ClusterNode("redis-dst-0.redis-dst-headless.<namespace>.svc.cluster.local", 6379),
]


def src_remap(address):
    """Rewrite bare node names to fully-qualified in-cluster hostnames."""
    host, port = address
    if host.endswith(".svc.cluster.local"):
        return (host, port)
    return (f"{host}.redis-src-headless.<namespace>.svc.cluster.local", port)


def dst_remap(address):
    host, port = address
    if host.endswith(".svc.cluster.local"):
        return (host, port)
    return (f"{host}.redis-dst-headless.<namespace>.svc.cluster.local", port)


src = RedisCluster(
    startup_nodes=SRC_STARTUP_NODES,
    password=SRC_PASS,
    address_remap=src_remap,
    **TLS,
)

dst = RedisCluster(
    startup_nodes=DST_STARTUP_NODES,
    password=DST_PASS,
    address_remap=dst_remap,
    **TLS,
)


def copy_stream(k):
    entries = src.xrange(k, min="-", max="+")
    if entries:
        for entry_id, fields in entries:
            try:
                dst.xadd(k, fields, id=entry_id)
            except ResponseError as e:
                if "equal or smaller" not in str(e):
                    raise  # already-migrated entries are expected on rerun

    try:
        groups = src.xinfo_groups(k)
    except Exception:
        groups = []

    for g in groups:
        gname = g["name"]
        last_id = g["last-delivered-id"]
        try:
            dst.xgroup_create(k, gname, id=last_id, mkstream=True)
        except ResponseError as e:
            if "BUSYGROUP" not in str(e):
                print(f"    [WARN] group {gname} on {k}: {e}")

    return True


def copy_key(k):
    t = src.type(k)
    ttl = src.pttl(k)
    ttl = ttl if ttl and ttl > 0 else 0

    if t == b"string":
        dst.set(k, src.get(k))
    elif t == b"hash":
        data = src.hgetall(k)
        if data:
            dst.hset(k, mapping=data)
    elif t == b"list":
        vals = src.lrange(k, 0, -1)
        if vals:
            dst.delete(k)
            dst.rpush(k, *vals)
    elif t == b"set":
        vals = src.smembers(k)
        if vals:
            dst.sadd(k, *vals)
    elif t == b"zset":
        vals = src.zrange(k, 0, -1, withscores=True)
        if vals:
            dst.zadd(k, dict((m, s) for m, s in vals))
    elif t == b"stream":
        return copy_stream(k)
    else:
        print(f"  [SKIP] unknown type {t} for key: {k}")
        return False

    if ttl > 0:
        dst.pexpire(k, ttl)
    return True


def main():
    migrated = 0
    skipped = 0
    for k in src.scan_iter(count=500):
        try:
            ok = copy_key(k)
        except Exception as e:
            print(f"  [ERROR] key {k}: {e}")
            ok = False
        if ok:
            migrated += 1
        else:
            skipped += 1
        if migrated % 500 == 0 and migrated:
            print(f"  ... {migrated} migrated so far")

    print(f"TOTAL MIGRATED: {migrated}, SKIPPED: {skipped}")


if __name__ == "__main__":
    main()

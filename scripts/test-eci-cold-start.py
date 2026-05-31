#!/usr/bin/env python3
"""阿里云 ECI 冷启动测速: CreateContainerGroup -> Running 计时, N 次, 用完删除。
对标 optima-infra-lab AWS 侧 test-task-startup.py (run-task -> RUNNING)。
在 buildbox 上跑 (aliyun CLI + profile aliyun-optima, 在 cn-prod VPC 内)。
用法: python3 eci_bench.py <image> [iterations] [cpu] [mem] [--image-cache]
"""
import subprocess, json, time, sys, os

REGION = "cn-beijing"
# 可选: 私有 ACR 拉取凭证 (环境变量传入)
REG_SERVER = os.getenv("ECI_REG_SERVER", "")
REG_USER = os.getenv("ECI_REG_USER", "")
REG_PASS = os.getenv("ECI_REG_PASS", "")
PROFILE = "aliyun-optima"
VSWITCH = "vsw-2zewcrp1wwj5gzz95ezsw"      # optima-cn-prod-vsw-main (cn-beijing-h)
SG = "sg-2ze2xgl1168yb176xjw3"              # optima-cn-prod-buildbox-sg

def cli(*args):
    r = subprocess.run(["aliyun", "eci", *args, "--region", REGION, "--profile", PROFILE],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"aliyun eci {args[0]} failed: {r.stderr.strip()[:300]}")
    return json.loads(r.stdout) if r.stdout.strip() else {}

def create(name, image, cpu, mem, use_cache):
    args = ["CreateContainerGroup", "--RegionId", REGION,
            "--SecurityGroupId", SG, "--VSwitchId", VSWITCH,
            "--ContainerGroupName", name, "--Cpu", str(cpu), "--Memory", str(mem),
            "--RestartPolicy", "Never",
            "--Container.1.Name", "c1", "--Container.1.Image", image,
            "--Container.1.Command.1", "sleep", "--Container.1.Arg.1", "300"]
    if use_cache:
        args += ["--ImageSnapshotId", "auto"]  # auto 匹配/自动建镜像缓存
    return cli(*args)["ContainerGroupId"]

def wait_running(cg_id, timeout=180):
    start = time.time()
    while True:
        if time.time() - start > timeout:
            raise TimeoutError("not Running in %ds" % timeout)
        d = cli("DescribeContainerGroups", "--ContainerGroupIds", json.dumps([cg_id]))
        gs = d.get("ContainerGroups", [])
        if gs:
            st = gs[0].get("Status")
            if st == "Running":
                return time.time() - start
            if st in ("Failed", "ScheduleFailed", "Expired"):
                raise RuntimeError("bad status: %s / %s" % (st, json.dumps(gs[0].get("Events", []))[:300]))
        time.sleep(0.5)

def delete(cg_id):
    try: cli("DeleteContainerGroup", "--ContainerGroupId", cg_id)
    except Exception as e: print("  (delete warn: %s)" % e)

def stats(v):
    s = sorted(v); n = len(s)
    return dict(avg=sum(v)/n, min=min(v), max=max(v),
                p50=s[int(n*0.5)], p95=s[min(int(n*0.95), n-1)])

def main():
    image = sys.argv[1]
    iters = int(sys.argv[2]) if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else 3
    cpu = sys.argv[3] if len(sys.argv) > 3 and not sys.argv[3].startswith("--") else "0.5"
    mem = sys.argv[4] if len(sys.argv) > 4 and not sys.argv[4].startswith("--") else "1.0"
    use_cache = "--image-cache" in sys.argv
    print("=== ECI cold-start bench ===")
    print(f"image={image} iters={iters} cpu={cpu} mem={mem} image_cache={use_cache}")
    times = []
    for i in range(iters):
        name = f"eci-bench-{int(time.time())}-{i}"
        cg = None
        try:
            t0 = time.time()
            cg = create(name, image, cpu, mem, use_cache)
            elapsed = wait_running(cg)
            times.append(elapsed)
            print(f"  iter {i+1}/{iters}: {elapsed*1000:.0f} ms  (cg={cg})")
        except Exception as e:
            print(f"  iter {i+1}/{iters}: ERROR {e}")
        finally:
            if cg: delete(cg)
            time.sleep(2)
    if times:
        s = stats(times)
        print("--- stats (ms) ---")
        print(f"  avg={s['avg']*1000:.0f}  min={s['min']*1000:.0f}  max={s['max']*1000:.0f}  p50={s['p50']*1000:.0f}  p95={s['p95']*1000:.0f}")

if __name__ == "__main__":
    main()

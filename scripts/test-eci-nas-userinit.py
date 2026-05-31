#!/usr/bin/env python3
"""验证 agent-runtime 路径: ECI 挂共享 NAS(用户无关) + 容器内 user-init 计时。
对标 AWS test-efs-latency(完整用户初始化 33ms)。在 buildbox 跑。
创建一个挂 NAS 的 ECI, 容器内跑 N 次 user-init(mkdir+写token+读), 用 date 秒级测批量算 avg,
顺便 df 证明 NAS 挂上了; 读容器日志拿结果; 用完删 ECI + 清测试目录。
"""
import subprocess, json, time, sys

REGION = "cn-beijing"; PROFILE = "aliyun-optima"
VSWITCH = "vsw-2zewcrp1wwj5gzz95ezsw"; SG = "sg-2ze2xgl1168yb176xjw3"
NAS = "01228x9017u1tbxi43v-vot10.cn-beijing.nas.aliyuncs.com"  # cn-prod VPC NAS
IMAGE = "registry.cn-hangzhou.aliyuncs.com/acs/busybox:latest"
N = 500

def cli(*a):
    r = subprocess.run(["aliyun","eci",*a,"--region",REGION,"--profile",PROFILE],
                       capture_output=True,text=True)
    if r.returncode != 0: raise RuntimeError(f"{a[0]}: {r.stderr.strip()[:400]}")
    return json.loads(r.stdout) if r.stdout.strip() else {}

ts = str(int(time.time()))
testdir = f"/mnt/nas/eci-bench-{ts}"
# 容器内脚本: df 证明挂载; N 次 user-init 计时(秒级 date, 批量算 avg ms); 清理
script = (
    f'echo MOUNT-OK; df -h /mnt/nas | tail -1; '
    f'D={testdir}; N={N}; S=$(date +%s); i=0; '
    f'while [ $i -lt $N ]; do mkdir -p $D/user-$i/.optima; '
    f'echo \'{{"token":"x"}}\' > $D/user-$i/.optima/token.json; '
    f'cat $D/user-$i/.optima/token.json > /dev/null; i=$((i+1)); done; '
    f'E=$(date +%s); echo "NAS-USERINIT n=$N total=$((E-S))s avg_ms=$(( (E-S)*1000/N ))"; '
    f'rm -rf $D; echo DONE; sleep 120'
)

name = f"eci-nas-test-{ts}"
print(f"=== ECI + NAS 路径验证 (NAS={NAS}, user-init N={N}) ===")
t0 = time.time()
cg = cli("CreateContainerGroup","--RegionId",REGION,"--SecurityGroupId",SG,"--VSwitchId",VSWITCH,
    "--ContainerGroupName",name,"--Cpu","1.0","--Memory","2.0","--RestartPolicy","Never",
    "--Volume.1.Name","nasvol","--Volume.1.Type","NFSVolume",
    "--Volume.1.NFSVolume.Server",NAS,"--Volume.1.NFSVolume.Path","/","--Volume.1.NFSVolume.ReadOnly","false",
    "--Container.1.Name","c1","--Container.1.Image",IMAGE,
    "--Container.1.VolumeMount.1.Name","nasvol","--Container.1.VolumeMount.1.MountPath","/mnt/nas",
    "--Container.1.Command.1","sh","--Container.1.Arg.1=-c","--Container.1.Arg.2",script)["ContainerGroupId"]
print(f"created cg={cg}")
try:
    # 等 Running
    while True:
        if time.time()-t0 > 180: print("TIMEOUT waiting Running"); break
        gs = cli("DescribeContainerGroups","--ContainerGroupIds",json.dumps([cg])).get("ContainerGroups",[])
        if gs and gs[0].get("Status")=="Running":
            print(f"cold-start(挂NAS) -> Running: {(time.time()-t0)*1000:.0f} ms"); break
        if gs and gs[0].get("Status") in ("Failed","ScheduleFailed"):
            print("FAILED:", json.dumps(gs[0].get("Events",[]))[:400]); break
        time.sleep(0.5)
    # 读容器日志拿 user-init 结果(等脚本跑完)
    for _ in range(30):
        time.sleep(3)
        try:
            log = cli("DescribeContainerLog","--RegionId",REGION,"--ContainerGroupId",cg,"--ContainerName","c1").get("Content","")
        except Exception as e:
            log = f"(log err {e})"
        if "DONE" in log:
            print("--- 容器日志 ---"); print(log.strip()); break
    else:
        print("--- 日志(未见 DONE,可能还在跑) ---"); print(log.strip()[:800])
finally:
    try: cli("DeleteContainerGroup","--ContainerGroupId",cg); print(f"deleted {cg}")
    except Exception as e: print("delete warn", e)

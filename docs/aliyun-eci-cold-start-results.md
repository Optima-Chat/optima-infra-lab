# 阿里云 ECI 冷启动测试结果(cn-prod,agent-runtime 候选)

> 测试日期: 2026-05-31 · 区域: cn-beijing · 在 buildbox(cn-prod VPC 内)用 aliyun CLI 跑
> 脚本: `scripts/test-eci-cold-start.py`(对标 AWS 侧 `test-task-startup.py`,计时 CreateContainerGroup → Status=Running)
> 背景: agent-runtime 阿里云形态选 ECI 按需(见 optima-terraform docs/cn-prod/design-agent-runtime-warmpool.md / issue #84)

## 结果:ECI 冷启动分布(busybox 极小镜像,N=8,无 ImageCache)

| 指标 | 值 |
|---|---|
| p50 | **3.3s** |
| min | 2.6s |
| p95 / max | **29s** |
| avg | 9.6s |

原始: `3238, 3258, 28817, 3258, 3212, 29405, 3196, 2576` (ms) —— 8 次里 6 次 ~3s,2 次 ~29s。

## 关键发现

1. **平时 ~3s(接近秒级),但约 1/4 概率飙到 ~29s** —— 阿里云现开沙箱/弹性网卡的尾延迟。
2. busybox 几乎无镜像 → 这 ~3s/~29s 是**纯 provisioning 开销,与镜像大小无关**。
3. **ImageCache 救不了这条尾巴**(它只省拉镜像);大镜像冷启会在此之上再叠拉取时间(阿里云官方:386MB 镜像 50s→缓存后 5s)。
4. **要消掉 29s 尾巴只能靠"预热在跑的 ECI 池"**(分配即用)。阿里云无 AWS"停机 warm pool"等价物(停机只付存储),预热=常驻在跑,靠 spot/包月压单价。

## 对比 AWS(见 task-prewarming-results.md / ec2-warm-pool-results.md)

| 场景 | AWS | 阿里云 ECI |
|---|---|---|
| 按需冷启(serverless) | Fargate ~12s | **p50 3.3s / p95 29s** |
| 预热池里已 RUNNING,分配 | **~260ms-1s** | 同理(切目录+init_user,待实测) |
| 预热省钱手段 | 停机 EC2 只付 EBS | 无停机等价物,靠 spot/包月 |

## 预热的权限前提(AWS 教训)

AWS 当年卡在"每用户 EFS AP 绑身份→没法预热用户无关 task",改"共享 AP + 应用层目录隔离"解决。
**阿里云 NAS 无 EFS AP 同款概念**(Volume 直接挂 server+path,权限组是 IP 级),共享挂载+目录隔离是默认形态,
**预热用户无关 ECI 直接成立,比 AWS 省一步**。详见 optima-terraform design-agent-runtime-warmpool.md。

## 复现

```bash
# 在 buildbox (cn-prod VPC 内, aliyun CLI profile aliyun-optima):
python3 scripts/test-eci-cold-start.py <image> [iterations] [cpu] [mem] [--image-cache]
# 例: python3 scripts/test-eci-cold-start.py registry.cn-hangzhou.aliyuncs.com/acs/busybox:latest 8
# 私有 ACR: 设 ECI_REG_SERVER/ECI_REG_USER/ECI_REG_PASS 环境变量
```
脚本会创建临时 ECI、计时到 Running、用完即删。VSwitch/SG 在脚本顶部(cn-prod-vsw-main / buildbox-sg)。

## TODO(未做)
- 真实 agent-runtime 体积镜像(数百 MB~GB)冷启 + ImageCache 对比(busybox 无镜像,未体现拉取/缓存差异)。
- "预热在跑的 ECI 复用分配"延迟实测(对标 AWS 260ms)。

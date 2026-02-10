# 10 - Kubernetes 与容器编排

> 云原生的事实标准：从 ECS 使用者视角理解 K8s

---

## 我们现在在哪

```
Optima 当前的容器编排：AWS ECS

✅ 做得好的:
  - ECS + EC2 Launch Type，成本可控（~$43/月 Stage）
  - Service Auto Scaling（CPU > 70% 扩容）
  - Cloud Map 服务发现（*.optima-stage.local）
  - ALB + Listener Rules 路由
  - Terraform 管理所有资源

⚠️ 感受到的限制:
  - 服务间通信只能用 Cloud Map DNS（无流量控制、无 mTLS）
  - 部署策略只有滚动更新（ECS 的蓝绿依赖 CodeDeploy，配置复杂）
  - 没有声明式的配置管理（ConfigMap/Secret 依赖 Infisical + 环境变量）
  - 调试困难：想 exec 进容器要用 ECS Exec + SSM，步骤繁琐
  - 本地开发无法模拟 ECS 环境
  - 生态有限：想用的开源工具（Prometheus/Grafana/Jaeger）都是 K8s 原生
```

**为什么还用 ECS**: 团队规模小、服务数不多（5 个核心 + 7 个 MCP）、AWS 全家桶集成好、不需要额外运维 Control Plane。这是**正确的决策** — K8s 的运维成本在当前阶段不值得。

**为什么要学 K8s**: 因为它是行业事实标准。无论是面试、看开源项目、还是未来服务规模增长后的架构选型，K8s 都是绕不过去的知识。

---

## K8s 架构总览

### 先建立直觉：K8s 就是一个"声明式的期望状态引擎"

你告诉 K8s "我要 3 个 user-auth 实例"，K8s 会持续工作确保集群中始终有 3 个在运行。挂了一个？自动补一个。节点挂了？把上面的 Pod 重新调度到其他节点。

这和你在 ECS 中做的事情一样 — `desired_count: 3` — 但 K8s 把这个模式推广到了**一切**资源。

### 架构图

```
┌──────────────────────────────────────────────────────────────┐
│                      Control Plane                           │
│                                                              │
│  ┌──────────┐  ┌───────────┐  ┌────────────┐  ┌──────────┐  │
│  │   API    │  │   etcd    │  │ Scheduler  │  │Controller│  │
│  │  Server  │  │ (KV存储)  │  │ (调度器)    │  │ Manager  │  │
│  └────┬─────┘  └───────────┘  └────────────┘  └──────────┘  │
│       │                                                      │
│  所有操作都通过 API Server                                     │
│  kubectl → API Server → etcd                                 │
└───────┼──────────────────────────────────────────────────────┘
        │
        │  kubelet 定期汇报状态
        │  API Server 下发调度指令
        │
┌───────┼──────────────────────────────────────────────────────┐
│       ▼          Worker Node                                 │
│  ┌──────────┐  ┌────────────┐  ┌──────────────────────────┐  │
│  │ kubelet  │  │ kube-proxy │  │   Container Runtime      │  │
│  │(节点代理) │  │ (网络代理)  │  │ (containerd / CRI-O)    │  │
│  └──────────┘  └────────────┘  └──────────────────────────┘  │
│                                                              │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                      │
│  │  Pod A  │  │  Pod B  │  │  Pod C  │                      │
│  │(容器组)  │  │(容器组)  │  │(容器组)  │                      │
│  └─────────┘  └─────────┘  └─────────┘                      │
└──────────────────────────────────────────────────────────────┘
```

### 各组件职责

| 组件 | ECS 对应 | 职责 |
|------|---------|------|
| **API Server** | ECS API / AWS API | K8s 的前端，所有操作都通过它。kubectl、Dashboard、CI/CD 都是调 API Server |
| **etcd** | 无直接对应（AWS 内部管理） | 分布式 KV 存储，存所有集群状态。挂了 = 集群完蛋 |
| **Scheduler** | ECS Task Placement | 决定 Pod 放到哪个 Node。考虑资源、亲和性、污点等 |
| **Controller Manager** | ECS Service Scheduler | 跑各种控制循环：Deployment Controller、ReplicaSet Controller 等 |
| **kubelet** | ECS Agent | 每个 Node 上的代理，负责管理 Pod 生命周期 |
| **kube-proxy** | 无（ECS 用 ALB/Cloud Map） | 维护 Node 上的网络规则，实现 Service 的负载均衡 |
| **Container Runtime** | Docker / containerd | 实际运行容器。K8s 1.24+ 移除了 Docker，用 containerd |

**关键区别**: ECS 的 Control Plane 是 AWS 托管的黑盒（你不用管），K8s 的 Control Plane 需要你自己运维（除非用 EKS/GKE 等托管服务）。

---

## 核心工作负载

### Pod：为什么不是容器？

Pod 是 K8s 的最小调度单位。一个 Pod 可以包含多个容器。

**为什么？** 因为有些容器必须紧密协作：

```yaml
# 一个典型的 sidecar 模式
apiVersion: v1
kind: Pod
metadata:
  name: user-auth
spec:
  containers:
    # 主容器：你的业务服务
    - name: user-auth
      image: 585891120210.dkr.ecr.ap-southeast-1.amazonaws.com/user-auth:latest
      ports:
        - containerPort: 8000

    # Sidecar：日志收集
    - name: log-agent
      image: fluent/fluent-bit:latest
      volumeMounts:
        - name: logs
          mountPath: /var/log/app

    # Sidecar：Envoy 代理（Service Mesh 场景）
    - name: envoy-proxy
      image: envoyproxy/envoy:v1.28
      ports:
        - containerPort: 9901

  volumes:
    - name: logs
      emptyDir: {}
```

**同一个 Pod 内的容器**:
- 共享网络命名空间（localhost 互通）
- 共享存储卷
- 同时调度到同一个 Node
- 同生共死（Pod 删除 = 所有容器停止）

**对比 ECS**: ECS 的 Task Definition 也能定义多个容器（sidecar pattern），但用得少。K8s 的 sidecar 是核心设计，Service Mesh 就是靠自动注入 sidecar 实现的。

### Deployment：声明式的滚动更新

你不直接管 Pod，而是管 Deployment。Deployment 管 ReplicaSet，ReplicaSet 管 Pod。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: user-auth
  namespace: optima-stage
spec:
  replicas: 2
  selector:
    matchLabels:
      app: user-auth
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # 更新时最多多出 1 个 Pod
      maxUnavailable: 0   # 更新时不允许少于期望数量
  template:
    metadata:
      labels:
        app: user-auth
        version: v1.2.3
    spec:
      containers:
        - name: user-auth
          image: user-auth:v1.2.3
          ports:
            - containerPort: 8000
          resources:
            requests:          # 最低保证
              memory: "256Mi"
              cpu: "250m"      # 0.25 vCPU
            limits:            # 上限
              memory: "512Mi"
              cpu: "500m"
          readinessProbe:      # 就绪检查（通过后才接收流量）
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:       # 存活检查（失败则重启容器）
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 20
```

**滚动更新过程**:

```
初始状态:  [v1] [v1]

更新到 v2:
  Step 1:  [v1] [v1] [v2]     ← 新建一个 v2 (maxSurge: 1)
  Step 2:  [v1] [v2] [v2]     ← v2 就绪后，终止一个 v1
  Step 3:  [v2] [v2]          ← 全部切换完成

回滚:
  kubectl rollout undo deployment/user-auth
  → 自动回到上一个 ReplicaSet 版本
```

**对比 ECS**: ECS 的 `force-new-deployment` 做的事情类似，但回滚要手动改镜像 tag 再部署。K8s 的 `rollout undo` 是一键操作，且保留历史版本。

### StatefulSet：有状态服务

**什么时候用**: 数据库、消息队列、分布式存储等需要稳定网络标识和持久存储的服务。

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres
  replicas: 3
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:15
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:        # 每个 Pod 自动创建独立的 PVC
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3
        resources:
          requests:
            storage: 100Gi
```

**StatefulSet vs Deployment 关键区别**:

| 特性 | Deployment | StatefulSet |
|------|-----------|-------------|
| Pod 名称 | 随机（user-auth-7d8f9-abc12） | 有序（postgres-0, postgres-1） |
| 存储 | 所有 Pod 共享或无状态 | 每个 Pod 独立 PVC |
| 扩缩顺序 | 随机 | 有序（0→1→2 创建，2→1→0 删除） |
| 网络标识 | 无固定 DNS | 固定 DNS（postgres-0.postgres.ns.svc） |
| 适用场景 | 无状态服务 | 数据库、Redis 集群、Kafka |

**Optima 场景**: 我们用 RDS 和 ElastiCache 这些托管服务，不需要自己跑 StatefulSet。但理解它很重要 — 如果你用自建 K8s，数据库就得用 StatefulSet + Operator 管理。

### DaemonSet 和 Job/CronJob

```yaml
# DaemonSet：每个 Node 跑一个（监控、日志收集）
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      containers:
        - name: node-exporter
          image: prom/node-exporter:latest
          ports:
            - containerPort: 9100

---
# CronJob：定时任务
apiVersion: batch/v1
kind: CronJob
metadata:
  name: db-backup
spec:
  schedule: "0 2 * * *"      # 每天凌晨 2 点
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: backup
              image: postgres:15
              command: ["pg_dump", "-h", "postgres", "-U", "admin", "-d", "optima"]
          restartPolicy: OnFailure
```

**对比 ECS**: ECS 没有 DaemonSet 概念（你得手动确保每台 EC2 跑一个 Task）。ECS Scheduled Tasks 对应 CronJob，但配置更繁琐。

---

## 服务发现与网络

### K8s 网络模型的核心假设

1. **每个 Pod 有独立 IP**（不是共享 Node IP）
2. **Pod 间可以直接通信**（无需 NAT）
3. **Node 和 Pod 可以直接通信**

这靠 **CNI 插件**实现（Calico、Cilium、AWS VPC CNI 等）。

### Service：四种类型

```yaml
# ClusterIP（默认）：集群内部访问
apiVersion: v1
kind: Service
metadata:
  name: user-auth
  namespace: optima
spec:
  type: ClusterIP
  selector:
    app: user-auth
  ports:
    - port: 80            # Service 端口
      targetPort: 8000    # Pod 端口
# 集群内访问: http://user-auth.optima.svc.cluster.local
```

| 类型 | 可访问范围 | ECS 对应 | 使用场景 |
|------|----------|---------|---------|
| **ClusterIP** | 集群内部 | Cloud Map 内部 DNS | 服务间通信（最常用） |
| **NodePort** | Node IP:端口 | EC2 安全组放开端口 | 开发/测试，生产少用 |
| **LoadBalancer** | 外网（通过云 LB） | ALB Target Group | 面向用户的服务 |
| **ExternalName** | CNAME 到外部 DNS | 无直接对应 | 访问集群外服务（如 RDS） |

```yaml
# LoadBalancer 示例 — 在 AWS 上会自动创建 NLB/ALB
apiVersion: v1
kind: Service
metadata:
  name: user-auth-public
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
spec:
  type: LoadBalancer
  selector:
    app: user-auth
  ports:
    - port: 443
      targetPort: 8000

---
# ExternalName — 把外部 RDS 映射为集群内服务名
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  type: ExternalName
  externalName: optima-prod-postgres.ctg866o0ehac.ap-southeast-1.rds.amazonaws.com
# 集群内用 postgres.optima.svc 就能访问 RDS
```

**对比 Optima 当前**: 我们用 Cloud Map 做服务发现（`user-auth-ecs.optima-stage.local:8000`），K8s 的 ClusterIP Service 做的是同样的事 — 提供一个稳定的 DNS 名指向后端 Pod。区别在于 K8s 是内建功能，不需要额外配置。

### Ingress Controller

Ingress 相当于 ALB 的 Listener Rules — 根据域名/路径把流量路由到不同 Service。

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: optima-ingress
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - auth.stage.optima.onl
        - api.stage.optima.onl
      secretName: optima-tls
  rules:
    - host: auth.stage.optima.onl
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: user-auth
                port:
                  number: 80
    - host: api.stage.optima.onl
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: commerce-backend
                port:
                  number: 80
```

**常见 Ingress Controller**:
- **NGINX Ingress**: 最常用，社区版免费
- **AWS ALB Ingress Controller**: 把 Ingress 映射为 ALB 规则（EKS 推荐）
- **Traefik**: 自动 Let's Encrypt、配置热更新
- **Istio Gateway**: Service Mesh 场景

**对比 Optima**: 我们在 Terraform 中配 ALB Listener Rules + Route53 记录来路由流量。K8s 用一个 Ingress YAML 就搞定了同样的事，而且改路由不需要改 Terraform。

### CNI 插件简介

CNI (Container Network Interface) 负责实现 K8s 的网络模型。

| CNI 插件 | 特点 | 适用场景 |
|---------|------|---------|
| **AWS VPC CNI** | Pod 直接获取 VPC IP，安全组直接适用 | EKS（推荐） |
| **Calico** | eBPF/iptables，支持 Network Policy | 通用，自建集群 |
| **Cilium** | eBPF 原生，性能好，内置可观测性 | 高性能需求，Service Mesh 替代 |
| **Flannel** | 简单，VXLAN overlay | 学习/小集群 |

**EKS 用户选 AWS VPC CNI**: Pod 直接拿 VPC 子网 IP，和 EC2 实例在同一个网络平面。好处是 Pod 可以直接被安全组保护，也可以直接访问 RDS 等 VPC 内资源。

---

## 配置与密钥管理

### ConfigMap 和 Secret

```yaml
# ConfigMap — 非敏感配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-auth-config
  namespace: optima
data:
  NODE_ENV: "staging"
  LOG_LEVEL: "info"
  DB_HOST: "postgres.optima.svc"
  DB_PORT: "5432"
  # 也可以放整个配置文件
  config.yaml: |
    server:
      port: 8000
      cors:
        origins:
          - https://stage.optima.onl

---
# Secret — 敏感信息（Base64 编码，不是加密！）
apiVersion: v1
kind: Secret
metadata:
  name: user-auth-secrets
  namespace: optima
type: Opaque
data:
  DB_PASSWORD: cGFzc3dvcmQxMjM=        # echo -n 'password123' | base64
  JWT_SECRET: bXktand0LXNlY3JldA==
```

### 使用方式：环境变量 vs Volume 挂载

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: user-auth
spec:
  template:
    spec:
      containers:
        - name: user-auth
          image: user-auth:latest

          # 方式 1：环境变量（适合少量配置）
          env:
            - name: DB_HOST
              valueFrom:
                configMapKeyRef:
                  name: user-auth-config
                  key: DB_HOST
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: user-auth-secrets
                  key: DB_PASSWORD

          # 方式 2：整个 ConfigMap 作为环境变量
          envFrom:
            - configMapRef:
                name: user-auth-config

          # 方式 3：Volume 挂载（适合配置文件）
          volumeMounts:
            - name: config
              mountPath: /app/config
              readOnly: true

      volumes:
        - name: config
          configMap:
            name: user-auth-config
            items:
              - key: config.yaml
                path: config.yaml
```

**环境变量 vs Volume 挂载**:

| | 环境变量 | Volume 挂载 |
|---|---------|-----------|
| 适合 | 简单 KV 配置 | 配置文件 |
| 热更新 | 需要重启 Pod | ConfigMap 更新后自动同步（~1分钟） |
| 大小限制 | 受环境变量总大小限制 | ConfigMap 上限 1MB |

**对比 Optima**: 我们用 Infisical 管理 secrets，ECS Task Definition 中配环境变量。K8s 原生就有 ConfigMap/Secret，还可以接入 External Secrets Operator 对接 Infisical/AWS Secrets Manager。

---

## 存储

### PV / PVC / StorageClass 三层抽象

```
管理员定义存储类型（StorageClass）
  ↓
开发者声明存储需求（PersistentVolumeClaim）
  ↓
K8s 自动创建实际存储（PersistentVolume）
```

```yaml
# StorageClass — 管理员定义（EKS 默认提供）
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com      # AWS EBS CSI Driver
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
reclaimPolicy: Delete              # PVC 删除时自动删 EBS
volumeBindingMode: WaitForFirstConsumer  # Pod 调度到 Node 后再创建 EBS

---
# PVC — 开发者声明 "我要 100GB gp3 存储"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
spec:
  accessModes:
    - ReadWriteOnce                # EBS 只能挂载到一个 Node
  storageClassName: gp3
  resources:
    requests:
      storage: 100Gi
```

### AWS EBS CSI Driver

在 EKS 上使用 EBS 作为持久存储的标准方式：

```bash
# 安装 EBS CSI Driver（EKS Add-on）
aws eks create-addon \
  --cluster-name optima-cluster \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::585891120210:role/ebs-csi-driver
```

**对比 Optima**: 我们的 ECS 服务都是无状态的（数据在 RDS/ElastiCache），不需要持久存储。K8s 的 PV/PVC 主要用于自建数据库或需要本地缓存的场景。

---

## Helm：K8s 的包管理器

### 为什么需要 Helm

一个服务部署到 K8s 至少需要：Deployment + Service + ConfigMap + Secret + Ingress + HPA。每个环境（dev/stage/prod）的配置还不同。手动管理 YAML 会疯。

**Helm 解决的问题**: 把一组相关的 K8s 资源打包成 **Chart**，用 **Values** 控制差异。

### Chart 结构

```
optima-user-auth/
├── Chart.yaml              # Chart 元信息
├── values.yaml             # 默认配置
├── values-stage.yaml       # Stage 覆盖
├── values-prod.yaml        # Prod 覆盖
└── templates/
    ├── deployment.yaml     # Deployment 模板
    ├── service.yaml        # Service 模板
    ├── ingress.yaml        # Ingress 模板
    ├── configmap.yaml      # ConfigMap 模板
    ├── hpa.yaml            # HPA 模板
    └── _helpers.tpl        # 模板辅助函数
```

```yaml
# Chart.yaml
apiVersion: v2
name: optima-user-auth
description: Optima User Authentication Service
version: 1.2.3
appVersion: "2.1.0"

# values.yaml（默认值）
replicaCount: 1
image:
  repository: 585891120210.dkr.ecr.ap-southeast-1.amazonaws.com/user-auth
  tag: "latest"
resources:
  requests:
    memory: "256Mi"
    cpu: "250m"
  limits:
    memory: "512Mi"
    cpu: "500m"
ingress:
  enabled: true
  host: ""                  # 必须在环境 values 中覆盖

# values-stage.yaml
replicaCount: 2
image:
  tag: "v1.2.3-rc1"
ingress:
  host: auth.stage.optima.onl
resources:
  requests:
    memory: "256Mi"

# values-prod.yaml
replicaCount: 4
image:
  tag: "v1.2.3"
ingress:
  host: auth.optima.shop
resources:
  requests:
    memory: "512Mi"
```

```yaml
# templates/deployment.yaml（Go 模板语法）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "optima-user-auth.fullname" . }}
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    spec:
      containers:
        - name: user-auth
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
```

### Helm 常用命令

```bash
# 安装 Chart（创建 Release）
helm install user-auth ./optima-user-auth \
  -f values-stage.yaml \
  -n optima-stage

# 升级（更新配置或镜像）
helm upgrade user-auth ./optima-user-auth \
  -f values-stage.yaml \
  --set image.tag=v1.2.4 \
  -n optima-stage

# 回滚
helm rollback user-auth 1    # 回到版本 1
helm history user-auth       # 查看所有版本

# 卸载
helm uninstall user-auth -n optima-stage

# 渲染模板（不部署，只看生成的 YAML）
helm template user-auth ./optima-user-auth -f values-stage.yaml
```

**对比 Optima**: 我们用 Terraform 管理 ECS 资源。如果迁移到 K8s，Helm Chart 取代的是 Terraform 中 ECS Task Definition + Service 的部分，但 VPC、RDS、ALB 这些基础设施仍然用 Terraform 管。

---

## Operator 模式

### 什么是 Operator

Operator = **CRD (Custom Resource Definition)** + **Controller**

K8s 原生只知道 Pod、Service 这些基础资源。你想让 K8s 管理 PostgreSQL 集群？K8s 不知道怎么做主从切换、备份恢复。

Operator 就是教 K8s "如何管理某种特定应用"的扩展：

```yaml
# CRD 定义了新资源类型
apiVersion: acid.zalan.do/v1
kind: postgresql                     # 自定义资源类型
metadata:
  name: optima-postgres
spec:
  teamId: optima
  numberOfInstances: 3               # 3 节点集群
  postgresql:
    version: "15"
  volume:
    size: 100Gi
    storageClass: gp3
  resources:
    requests:
      cpu: 500m
      memory: 1Gi

# Operator Controller 看到这个资源后会自动:
# 1. 创建 3 个 StatefulSet Pod
# 2. 配置主从复制
# 3. 设置自动 failover
# 4. 定时备份
# 5. 监控健康状态
```

### 为什么数据库/MQ 需要 Operator

普通 StatefulSet 只管容器的生命周期，不懂业务逻辑。数据库需要：

| 操作 | StatefulSet 能做 | Operator 能做 |
|------|-----------------|--------------|
| 启动/停止实例 | ✅ | ✅ |
| 主从切换 | ❌ | ✅ |
| 自动备份 | ❌ | ✅ |
| 扩缩容后的数据迁移 | ❌ | ✅ |
| 版本升级（rolling） | 部分 | ✅ |
| 自愈（主挂了自动选新主） | ❌ | ✅ |

### 常见 Operator

| Operator | 管理什么 |
|----------|---------|
| **Zalando Postgres Operator** | PostgreSQL 集群 |
| **Strimzi** | Apache Kafka |
| **Redis Operator (Spotahome)** | Redis 集群 |
| **Prometheus Operator** | Prometheus + Alertmanager |
| **Cert-Manager** | TLS 证书自动签发 |

**Optima 场景**: 我们用 RDS/ElastiCache 托管服务，不需要 Operator。但如果用自建 K8s 跑数据库（比如成本考虑），Operator 是必需品。

---

## Service Mesh

### 什么是 Service Mesh

Service Mesh 是处理**服务间通信**的基础设施层。它在每个 Pod 旁边注入一个 Sidecar 代理（通常是 Envoy），接管所有网络流量。

```
没有 Service Mesh:
  user-auth ──HTTP──→ commerce-backend
  - 明文传输
  - 没有重试/超时策略
  - 没有流量控制

有 Service Mesh:
  user-auth → [Envoy] ──mTLS──→ [Envoy] → commerce-backend
  - 自动 mTLS（加密 + 身份验证）
  - 重试、超时、熔断
  - 流量分割（金丝雀发布）
  - 指标收集
```

### 核心功能

#### 1. mTLS（双向 TLS）

服务间通信自动加密 + 双向身份验证，无需改业务代码：

```yaml
# Istio PeerAuthentication — 强制所有服务间通信使用 mTLS
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: optima
spec:
  mtls:
    mode: STRICT
```

#### 2. 流量管理

```yaml
# 金丝雀发布：90% 流量到 v1，10% 到 v2
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: user-auth
spec:
  hosts:
    - user-auth
  http:
    - route:
        - destination:
            host: user-auth
            subset: v1
          weight: 90
        - destination:
            host: user-auth
            subset: v2
          weight: 10

---
# 超时和重试策略
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: commerce-backend
spec:
  hosts:
    - commerce-backend
  http:
    - route:
        - destination:
            host: commerce-backend
      timeout: 5s
      retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: 5xx,reset,connect-failure
```

#### 3. 可观测性

Service Mesh 自动生成：
- **请求级指标**: 延迟 P50/P90/P99、错误率、QPS
- **分布式追踪**: Span 自动注入
- **服务拓扑图**: 可视化服务间依赖

### Istio vs Linkerd

| 特性 | Istio | Linkerd |
|------|-------|---------|
| 数据面代理 | Envoy | linkerd2-proxy (Rust) |
| 资源开销 | 较高 | 极低（~10MB/Pod） |
| 功能丰富度 | 最全面 | 够用，缺少部分高级功能 |
| 学习曲线 | 陡峭 | 平缓 |
| 适合团队 | 有专职平台工程师 | 小团队快速上手 |

### 何时需要引入 Service Mesh

```
✅ 需要引入:
  - 服务数量 > 20，调用链路复杂
  - 合规要求服务间通信加密（mTLS）
  - 需要细粒度流量控制（金丝雀、A/B、故障注入）
  - 跨团队协作，需要统一的可观测性

❌ 不需要:
  - 服务数少于 10（我们现在 5 个核心 + 7 个 MCP）
  - 团队没有专人维护 Mesh
  - 简单的负载均衡和健康检查就够用
```

**Optima 场景**: 当前不需要 Service Mesh。我们 12 个服务通过 Cloud Map + ALB 通信，没有 mTLS 需求，也不需要金丝雀发布。但如果服务数翻倍、或有合规要求，Linkerd 会是比较轻量的选择。

---

## ECS vs K8s 深度对比

### 功能对比表

| 维度 | ECS | Kubernetes |
|------|-----|------------|
| **Control Plane** | AWS 托管（免运维） | 自运维 / EKS 托管（$73/月） |
| **调度单位** | Task | Pod |
| **服务编排** | Service + Task Definition | Deployment + Service |
| **滚动更新** | ✅ ECS Service Update | ✅ Deployment Strategy |
| **蓝绿部署** | 需 CodeDeploy（复杂） | 原生支持（+ Argo Rollouts） |
| **金丝雀发布** | ❌ 不原生支持 | ✅ Ingress / Service Mesh |
| **服务发现** | Cloud Map（额外服务） | 内建 DNS（CoreDNS） |
| **配置管理** | Parameter Store / Infisical | ConfigMap + Secret（内建） |
| **自动扩容** | Service Auto Scaling | HPA / VPA / KEDA |
| **节点扩容** | ASG + Capacity Provider | Cluster Autoscaler / Karpenter |
| **日志** | CloudWatch Logs（awslogs driver） | Fluentd/Fluent Bit → 任意后端 |
| **监控** | CloudWatch Metrics | Prometheus + Grafana（更强大） |
| **网络** | awsvpc 模式（VPC 原生） | CNI 插件（灵活） |
| **存储** | EBS/EFS 挂载 | PV/PVC + CSI Driver |
| **包管理** | 无（Terraform 管理） | Helm Charts |
| **扩展性** | 有限（AWS API） | CRD + Operator（无限扩展） |
| **本地开发** | 无法本地模拟 | minikube/kind/k3s |
| **多云** | 锁定 AWS | 跨云可移植 |
| **生态** | AWS 生态 | CNCF 开源生态（巨大） |
| **学习曲线** | 低 | 高 |
| **运维成本** | 低（AWS 托管） | 高（自运维）/ 中等（EKS） |

### 适用场景决策树

```
你的团队有多大？
├─ < 5 人，服务 < 15 个
│   └─ ECS 就够了 ← Optima 在这里
│       优势：少运维、低成本、AWS 集成好
│
├─ 5-20 人，服务 15-50 个
│   └─ EKS（托管 K8s）
│       优势：K8s 生态 + AWS 减负 Control Plane
│       成本：$73/月 Control Plane + EC2/Fargate
│
└─ > 20 人，服务 > 50 个，多团队
    └─ 自建/多集群 K8s
        优势：完全控制、多云、平台工程
        成本：需要专职平台团队
```

### ECS Auto Scaling vs K8s HPA

```yaml
# ECS Service Auto Scaling（Terraform）
resource "aws_appautoscaling_target" "user_auth" {
  max_capacity       = 4
  min_capacity       = 1
  resource_id        = "service/optima-cluster/user-auth-stage"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "user_auth_cpu" {
  name               = "cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.user_auth.resource_id
  scalable_dimension = aws_appautoscaling_target.user_auth.scalable_dimension
  service_namespace  = aws_appautoscaling_target.user_auth.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 70.0
  }
}
```

```yaml
# K8s HPA
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: user-auth
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: user-auth
  minReplicas: 1
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    # K8s 还能基于自定义指标扩容（ECS 也能但配置更复杂）
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "100"
```

**关键区别**:
- K8s HPA 可以基于**自定义指标**扩容（通过 Prometheus Adapter）
- K8s 还有 **VPA**（垂直扩容，调整 CPU/内存）和 **KEDA**（事件驱动扩容，比如按 SQS 队列深度）
- ECS 靠 CloudWatch + Application Auto Scaling，功能更有限

### Cloud Map vs K8s Service Discovery

| | Cloud Map | K8s Service |
|---|----------|-------------|
| DNS | `*.optima-stage.local` | `*.svc.cluster.local` |
| 注册/注销 | ECS 自动管理 | K8s 自动管理 |
| 健康检查 | Route53 Health Check | kubelet + kube-proxy |
| 额外功能 | HTTP 命名空间（API 发现） | Headless Service（直接 Pod IP） |
| 成本 | 按查询收费（很少） | 免费（CoreDNS 内建） |

### 从 ECS 迁移到 K8s 的路径

如果未来 Optima 需要迁移：

```
阶段 0: 评估和准备（2-4 周）
  ├─ 创建 EKS 集群（Terraform + eksctl）
  ├─ 配置 VPC CNI、EBS CSI Driver
  ├─ 搭建 Prometheus + Grafana 监控
  └─ 团队 K8s 基础培训

阶段 1: 非关键服务迁移（2-4 周）
  ├─ MCP 工具服务（无状态，低风险）
  ├─ 为每个服务创建 Helm Chart
  ├─ 验证 Service Discovery 和 Ingress
  └─ 对比 ECS 和 K8s 上的性能

阶段 2: 核心服务迁移（4-8 周）
  ├─ user-auth → K8s（带 Infisical External Secrets）
  ├─ commerce-backend → K8s
  ├─ 流量从 ALB 逐步切换到 Ingress
  └─ 保留 ECS 服务作为回退

阶段 3: 下线 ECS（2 周）
  ├─ 确认所有服务在 K8s 上稳定运行
  ├─ 删除 ECS Terraform 资源
  └─ 更新 CI/CD Pipeline
```

**迁移的真实成本**:
- EKS Control Plane: $73/月（固定）
- 学习曲线：团队需要 2-4 周上手
- 运维复杂度增加：需要维护 Helm Charts、监控堆栈
- 好处要在服务数 > 15 时才能显现

**建议**: 目前不迁移。先在本地用 kind 熟悉 K8s，等服务规模或团队规模增长到 ECS 明显不够用时再考虑。

---

## 本地开发环境

### 工具选择

| 工具 | 特点 | 适合场景 | 资源开销 |
|------|------|---------|---------|
| **minikube** | 单节点，插件丰富 | 学习、单服务调试 | 2CPU/2GB |
| **kind** | Docker 容器模拟多节点 | CI/CD、本地测试 | 轻量 |
| **k3s** | 轻量级 K8s 发行版 | 边缘计算、树莓派 | 极轻量 |
| **Docker Desktop** | 内置 K8s | macOS/Windows 开发 | 较重 |

**推荐起步方案 — kind**:

```bash
# 安装 kind
go install sigs.k8s.io/kind@latest
# 或
brew install kind

# 创建集群（1 Control Plane + 2 Worker）
cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
      - containerPort: 443
        hostPort: 443
  - role: worker
  - role: worker
EOF

# 验证
kubectl get nodes
# NAME                 STATUS   ROLES           AGE   VERSION
# kind-control-plane   Ready    control-plane   1m    v1.31.0
# kind-worker          Ready    <none>          1m    v1.31.0
# kind-worker2         Ready    <none>          1m    v1.31.0

# 部署一个测试服务
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80
kubectl port-forward svc/nginx 8080:80
# 访问 http://localhost:8080

# 删除集群
kind delete cluster
```

### 开发体验工具

#### Tilt：本地开发的热重载

```python
# Tiltfile（Python 语法）
# 监控代码变更 → 自动构建镜像 → 自动部署到 K8s

# user-auth 服务
docker_build(
    'user-auth',
    './core-services/user-auth',
    live_update=[
        sync('./core-services/user-auth/src', '/app/src'),
        run('cd /app && npm install', trigger=['package.json']),
    ]
)
k8s_yaml('k8s/user-auth.yaml')
k8s_resource('user-auth', port_forwards='8000:8000')

# commerce-backend 服务
docker_build('commerce-backend', './core-services/commerce-backend')
k8s_yaml('k8s/commerce-backend.yaml')
k8s_resource('commerce-backend', port_forwards='8200:8200')
```

```bash
# 启动 Tilt
tilt up
# 打开 Dashboard: http://localhost:10350
# 修改代码 → 自动构建 + 部署（秒级）
```

#### Skaffold：CI/CD 友好的开发工具

```yaml
# skaffold.yaml
apiVersion: skaffold/v4beta6
kind: Config
build:
  artifacts:
    - image: user-auth
      context: core-services/user-auth
      docker:
        dockerfile: Dockerfile
deploy:
  helm:
    releases:
      - name: user-auth
        chartPath: charts/user-auth
        valuesFiles:
          - charts/user-auth/values-dev.yaml
        setValues:
          image.tag: "{{.IMAGE_TAG}}"
```

```bash
# 开发模式（监控变更 + 自动部署）
skaffold dev

# CI/CD 模式（构建 + 部署一次）
skaffold run --profile prod
```

**对比 Optima 当前**: 我们本地开发用 `docker compose` 跑单个服务，或直接 `npm run dev`。如果迁到 K8s，Tilt/Skaffold 能让本地开发体验接近直接跑 `npm run dev` 的速度，同时测试的是真实的 K8s 环境。

### 动手实验：用 kind 部署一个迷你 Optima

```bash
# 1. 创建集群
kind create cluster --name optima-lab

# 2. 创建 namespace
kubectl create namespace optima

# 3. 部署一个简单的 user-auth 模拟服务
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: user-auth
  namespace: optima
spec:
  replicas: 2
  selector:
    matchLabels:
      app: user-auth
  template:
    metadata:
      labels:
        app: user-auth
    spec:
      containers:
        - name: user-auth
          image: nginx:alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: user-auth
  namespace: optima
spec:
  selector:
    app: user-auth
  ports:
    - port: 80
      targetPort: 80
EOF

# 4. 验证
kubectl get pods -n optima
kubectl get svc -n optima

# 5. 测试服务发现
kubectl run test --rm -it --image=busybox -n optima -- \
  wget -qO- http://user-auth.optima.svc.cluster.local

# 6. 测试扩缩容
kubectl scale deployment user-auth -n optima --replicas=5
kubectl get pods -n optima -w   # 观察 Pod 创建过程

# 7. 测试滚动更新
kubectl set image deployment/user-auth user-auth=nginx:latest -n optima
kubectl rollout status deployment/user-auth -n optima

# 8. 测试回滚
kubectl rollout undo deployment/user-auth -n optima

# 9. 清理
kind delete cluster --name optima-lab
```

---

## 对 Optima 项目的思考

### 现在不做什么

1. **不迁移到 K8s** — ECS 完全满足当前需求，迁移的 ROI 为负
2. **不引入 Service Mesh** — 12 个服务不需要这个复杂度
3. **不自建 K8s 集群** — 如果要用，直接 EKS

### 可以做什么

1. **本地学习环境**: 用 kind 搭建一个本地集群，把 Optima 的 5 个核心服务的 Deployment YAML 写出来，理解 K8s 概念
2. **容器化标准**: 现有 Dockerfile 已经为 K8s 做好了准备 — 健康检查端点、环境变量配置、无状态设计
3. **关注 EKS**: 如果未来迁移，EKS + AWS VPC CNI + ALB Ingress Controller 是最自然的路径，基础设施变更最小

### 什么时候该迁移

```
信号:
  □ 服务数超过 20 个
  □ 团队超过 5 个工程师
  □ 需要金丝雀发布或更细粒度的流量控制
  □ 需要 mTLS 或零信任网络
  □ 开源工具集成需求增加（Prometheus/Grafana/ArgoCD）
  □ 多环境管理变得痛苦（dev/stage/prod/demo）

以上命中 3 个以上时，开始认真评估迁移。
```

---

## 推荐资源

### 入门

| 资源 | 类型 | 时间 | 说明 |
|------|------|------|------|
| [Kubernetes 官方教程](https://kubernetes.io/docs/tutorials/) | 交互教程 | 4h | 必做，浏览器内直接操作 |
| [Kubernetes The Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) | 实操 | 1-2 天 | 手动搭建 K8s，理解每个组件 |
| [kind Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/) | 文档 | 30min | 本地搭建集群最快方式 |

### 进阶

| 资源 | 类型 | 时间 | 说明 |
|------|------|------|------|
| [Kubernetes in Action (2nd Ed)](https://www.manning.com/books/kubernetes-in-action-second-edition) | 书 | 2-3 周 | 最好的 K8s 入门书，覆盖全面 |
| [Helm 官方文档](https://helm.sh/docs/) | 文档 | 3h | 包管理必读 |
| [Istio 官方文档 — Concepts](https://istio.io/latest/docs/concepts/) | 文档 | 3h | Service Mesh 概念 |
| [Prometheus 官方文档](https://prometheus.io/docs/introduction/overview/) | 文档 | 2h | K8s 监控标配 |

### 认证路径

| 认证 | 难度 | 费用 | 说明 |
|------|------|------|------|
| **CKAD** (Certified Kubernetes Application Developer) | 中等 | $395 | 侧重使用 K8s 部署应用，推荐先考这个 |
| **CKA** (Certified Kubernetes Administrator) | 较难 | $395 | 侧重集群管理和运维 |
| **CKS** (Certified Kubernetes Security Specialist) | 难 | $395 | 安全方向，需先通过 CKA |

**备考推荐**: [KodeKloud CKA/CKAD 课程](https://kodekloud.com/) + [killer.sh 模拟考试](https://killer.sh/)（买认证送两次模拟）

### 动手实验

1. **用 kind 搭建集群** → 部署 nginx → 创建 Service → 配置 Ingress（2h）
2. **写一个 Helm Chart** → 模板化 Deployment + Service + ConfigMap（3h）
3. **体验 HPA** → 用 hey/k6 打流量 → 观察 Pod 自动扩容（1h）
4. **尝试 Tilt** → 本地开发一个 Node.js 服务 → 体验热重载（2h）
5. **安装 Prometheus + Grafana** → Helm 一键部署 → 看 Dashboard（2h）

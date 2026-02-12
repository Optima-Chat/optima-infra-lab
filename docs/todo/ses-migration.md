# SES 邮件服务迁移 TODO

> 从 Resend 迁移到 AWS SES，发送域名 `optima.onl`

## 已完成

- [x] 创建 SES Terraform Stack（`optima-terraform/stacks/ses/`）
- [x] 域名验证 `optima.onl`（DKIM + SPF + DMARC + MAIL FROM）
- [x] Configuration Set `optima-email` + bounce/complaint SNS 告警
- [x] ecsTaskRole 添加 `ses:SendEmail` 权限
- [x] 创建 Infisical SMTP IAM 用户 `optima-ses-smtp`
- [x] user-auth 代码改造（`feature/ses-email` 分支，双 Provider 模式）
- [x] commerce-backend 代码改造（`feature/ses-email` 分支，双 Provider 模式）
- [x] 发送测试邮件验证（Gmail 收到，DKIM/SPF/DMARC pass）
- [x] Bounce 告警测试（SNS → 邮件 + Slack 都收到）
- [x] 提交 SES Production Access 申请（Case ID: `177086444100052`）

## 等待中

- [ ] **AWS 批准 SES Production Access**
  - Case ID: `177086444100052`
  - 已补充详细说明，等待 AWS 回复（~24h）
  - 批准前只能给已验证邮箱发（Sandbox 模式，200封/天）

## Production Access 批准后

### Stage 环境验证

- [ ] 合并 user-auth `feature/ses-email` → main
- [ ] 合并 commerce-backend `feature/ses-email` → main
- [ ] Infisical staging 环境添加 `EMAIL_PROVIDER=ses` + SES 相关配置
- [ ] 部署 Stage 环境，触发验证码邮件测试
- [ ] 测试 commerce-backend 订单确认邮件

### Prod 环境切换

- [ ] Stage 验证通过后，Infisical prod 设置 `EMAIL_PROVIDER=ses`
- [ ] 部署 Prod，观察邮件发送正常
- [ ] 验证 Yahoo、Gmail、Outlook 等主流邮箱都能收到

### Infisical SMTP 迁移

- [ ] 从 SES stack output 获取 SMTP 凭证：
  ```bash
  cd optima-terraform/stacks/ses
  terraform output -raw ses_smtp_username
  terraform output -raw ses_smtp_password
  ```
- [ ] 修改 `stacks/shared/201-infisical-ecs.tf` 中的 SMTP 配置：
  - `SMTP_HOST` → `email-smtp.ap-southeast-1.amazonaws.com`
  - `SMTP_PORT` → `587`
  - `SMTP_USERNAME` / `SMTP_PASSWORD` → SES SMTP 凭证
  - `SMTP_FROM_ADDRESS` → `noreply@optima.onl`
- [ ] `terraform apply` shared stack 并重启 Infisical ECS 服务

### 清理 Resend

- [ ] 确认所有环境邮件发送正常（观察 1-2 周）
- [ ] 删除 Infisical 中的 `RESEND_API_KEY` 配置
- [ ] 删除 SSM Parameter Store 中的 Resend 相关参数
- [ ] user-auth / commerce-backend 代码中移除 Resend provider 代码和 `resend` 依赖
- [ ] 注销 Resend 账户（可选）

## 相关资源

| 资源 | 位置 |
|------|------|
| SES Terraform Stack | `optima-terraform/stacks/ses/` |
| user-auth 分支 | `Optima-Chat/user-auth@feature/ses-email` |
| commerce-backend 分支 | `Optima-Chat/commerce-backend@feature/ses-email` |
| Infisical SMTP 配置 | `optima-terraform/stacks/shared/201-infisical-ecs.tf:164-192` |
| SNS 告警 Topic | `optima-infrastructure-alerts` |
| SES Configuration Set | `optima-email` |
| 发送域名 | `optima.onl`（发件地址 `noreply@optima.onl`） |

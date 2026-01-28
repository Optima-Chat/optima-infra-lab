/**
 * EFS Directory Manager
 *
 * 管理 EFS 上的用户目录
 */

import * as fs from 'fs';
import * as path from 'path';

export class EfsManager {
  private mountPath: string;
  private environment: string;

  constructor(mountPath: string = '/mnt/efs', environment: string = 'test') {
    this.mountPath = mountPath;
    this.environment = environment;
  }

  /**
   * 确保用户目录存在
   */
  async ensureUserDirectory(userId: string): Promise<string> {
    const userDir = this.getUserDirectory(userId);

    try {
      if (!fs.existsSync(userDir)) {
        fs.mkdirSync(userDir, { recursive: true, mode: 0o700 });
        console.log(`[EfsManager] Created directory: ${userDir}`);
      }

      // 确保权限正确
      fs.chmodSync(userDir, 0o700);

      // 创建子目录
      const subDirs = ['.optima', '.claude'];
      for (const subDir of subDirs) {
        const subDirPath = path.join(userDir, subDir);
        if (!fs.existsSync(subDirPath)) {
          fs.mkdirSync(subDirPath, { recursive: true, mode: 0o700 });
        }
      }

      return userDir;
    } catch (err) {
      console.error(`[EfsManager] Failed to create directory: ${userDir}`, err);
      throw err;
    }
  }

  /**
   * 获取用户目录路径
   */
  getUserDirectory(userId: string): string {
    return path.join(this.mountPath, this.environment, userId);
  }

  /**
   * 写入 token 文件
   */
  async writeToken(userId: string, token: string): Promise<void> {
    const userDir = await this.ensureUserDirectory(userId);
    const tokenDir = path.join(userDir, '.optima');
    const tokenFile = path.join(tokenDir, 'token.json');

    const tokenData = {
      env: this.environment,
      access_token: token,
      token_type: 'Bearer',
      expires_at: Date.now() + 24 * 60 * 60 * 1000,
    };

    fs.writeFileSync(tokenFile, JSON.stringify(tokenData, null, 2));
    console.log(`[EfsManager] Token written: ${tokenFile}`);
  }

  /**
   * 检查 EFS 是否挂载
   */
  isMounted(): boolean {
    return fs.existsSync(this.mountPath);
  }

  /**
   * 列出所有用户目录
   */
  listUserDirectories(): string[] {
    const envDir = path.join(this.mountPath, this.environment);

    if (!fs.existsSync(envDir)) {
      return [];
    }

    return fs.readdirSync(envDir).filter((name) => {
      const stat = fs.statSync(path.join(envDir, name));
      return stat.isDirectory();
    });
  }

  /**
   * 获取目录大小（字节）
   */
  getDirectorySize(userId: string): number {
    const userDir = this.getUserDirectory(userId);

    if (!fs.existsSync(userDir)) {
      return 0;
    }

    let totalSize = 0;
    const walkDir = (dir: string) => {
      const files = fs.readdirSync(dir);
      for (const file of files) {
        const filePath = path.join(dir, file);
        const stat = fs.statSync(filePath);
        if (stat.isDirectory()) {
          walkDir(filePath);
        } else {
          totalSize += stat.size;
        }
      }
    };

    walkDir(userDir);
    return totalSize;
  }
}

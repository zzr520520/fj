# AirChatPlus v6 – 最终稳定版

## 功能
- **启动弹窗**：确认插件注入成功
- **显示访客人数**：在帖子详情页顶部添加蓝色标签（从 `visitorCount`/`viewCount` 读取）

## 设计理念
- **只 Hook 一个方法**：`UIViewController.viewDidAppear:`，且只做一件事——发送通知
- **不触碰 UIButton**：避免触摸事件死锁
- **不触碰 NSURLSession**：避免网络回调异常
- **通知异步处理**：UI 操作在主队列异步执行，不阻塞原方法

## 编译
```bash
make
```

## 注入
使用轻松签等工具将 `AirChatPlus.dylib` 注入 `AirChat.ipa`，重签名后安装。

## 验证
- 打开 AirChat，弹出"已加载"提示
- 进入帖子详情页，若服务端返回了访客数，顶部出现蓝色标签

## 未包含
- 排行榜突破（需 Hook 网络层，有卡死风险）
- 权限弹窗拦截（需 Hook UIButton，有死锁风险）
- 访客列表查看（服务端硬性权限，无法绕过）

## 免责声明
本工具仅供技术学习，严禁用于商业或非法用途。

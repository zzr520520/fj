# AirChatPlus v7 – 诊断版（含文件日志 + 广泛类匹配）

## 功能
- **启动弹窗**：确认插件注入成功，显示 Hook 统计
- **文件日志**：所有操作记录写入 `Documents/AirChatPlus.log`
- **广泛类匹配**：遍历所有 ObjC 类，自动匹配 `Moment`+`Cell` 并 Hook setter
- **详情页访客标签**：匹配 `Detail`/`Moment`/`Post` 关键词的页面，从 `visitorCount`/`viewCount` 读取并显示
- **排行榜 pageSize 修改**：拦截包含 `rank` 的请求，将 `pageSize` 改为 500（GET/POST 均支持）
- **诊断信息**：日志中列出所有包含 `Detail` 或 `Moment`+`Controller` 的类名

## 编译
```bash
make
```

## 注入
使用轻松签等工具将 `AirChatPlus.dylib` 注入 `AirChat.ipa`，重签名后安装。

## 验证方法
1. 打开 AirChat，弹出"已注入"提示 → 插件加载成功
2. 无弹窗 → 检查签名和注入工具
3. 导出 `Documents/AirChatPlus.log` 查看完整日志（即使无弹窗也有日志）
4. 日志中可查看所有匹配到的类名和 Hook 结果

## 限制
- **访客数据**：服务端可能不返回 `visitorCount`/`viewCount` 给非作者，插件无法凭空创造数据
- **排行榜**：服务端可能硬性限制 `pageSize` 最大值，忽略客户端传入的 500
- **访客列表**：服务端硬性权限控制，客户端无法绕过

## 免责声明
本工具仅供技术学习，严禁用于商业或非法用途。

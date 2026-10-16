# tools/ 说明

本目录用于放置 **fnpack** —— 飞牛 fnOS 官方的应用打包命令行工具。

它是飞牛官方发布的第三方二进制，**不纳入 Git 仓库**（体积与再分发都不合适），
需要打包时请自行下载到本目录并重命名为 `fnpack.exe`。

- 官方文档：https://developer.fnnas.com/docs/cli/fnpack
- 注意：官方命令是 `build`，不是 `pack`

打包命令（在仓库根目录执行）：

```bash
./tools/fnpack.exe build qzonephoto
```

产物：`com.qzonephoto.app.fpk`（生成在工作目录，同样不入库）。

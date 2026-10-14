# 词慧 OCR 功能卡

基于 PaddleOCR 开源文档 AI 引擎的前后端完整功能模块。

## 功能特性

- 文字识别（中英文、数字、标点，50+ 种语言）
- 文档解析（版面分析、表格、公式、印章）
- 图片上传（点击 / 拖拽 / 拍照）
- 结果展示（完整文本、逐行详情、置信度标注）
- 一键复制识别结果

## 快速启动

**双击 `启动.bat`**，然后浏览器打开 http://localhost:8000

## 目录结构

```
cihui-ocr-card/
├── backend/
│   ├── main.py          # FastAPI 后端
│   └── ocr_service.py   # PaddleOCR 封装
├── frontend/
│   └── index.html       # 卡片式前端界面
├── uploads/
└── 启动.bat
```

## API 接口

| 接口 | 方法 | 说明 |
|---|---|---|
| `/api/health` | GET | 健康检查 |
| `/api/ocr/text` | POST | 文字识别 |
| `/api/ocr/document` | POST | 文档解析（表格/公式/印章） |
| `/api/ocr/auto` | POST | 自动模式 |

## 环境要求

- Python 3.12（已安装在 C:\Python312）
- 内存 2GB+
- 首次运行自动下载模型（约 1GB）

## 集成到词慧 App

1. WebView 嵌入：加载 http://localhost:8000
2. 直接调用 API：上传图片到对应接口
3. 部署到服务器：`uvicorn main:app --host 0.0.0.0 --port 8000`

## 开源协议

Apache 2.0，可免费商用

"""
词慧 App - OCR 功能卡后端服务
基于 PaddleOCR + FastAPI
"""
import os
import sys
import uuid
import logging
from pathlib import Path

from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse

from ocr_service import OCRService

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

BASE_DIR = Path(__file__).resolve().parent.parent
UPLOAD_DIR = BASE_DIR / "uploads"
FRONTEND_DIR = BASE_DIR / "frontend"
UPLOAD_DIR.mkdir(exist_ok=True)

app = FastAPI(
    title="词慧 OCR 功能卡",
    description="基于 PaddleOCR 的文档识别服务，支持文字/表格/公式/印章识别",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

ocr_service = OCRService()


@app.get("/api/health")
async def health_check():
    return ocr_service.health_check()


@app.post("/api/ocr/text")
async def ocr_text(file: UploadFile = File(...)):
    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="请上传图片文件")

    image_bytes = await file.read()
    if len(image_bytes) > 20 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="图片大小不能超过 20MB")

    try:
        result = ocr_service.recognize_text(image_bytes)
        logger.info(f"文字识别完成: {result['line_count']} 行, 耗时 {result['elapsed_ms']}ms")
        return result
    except Exception as e:
        logger.exception("文字识别失败")
        raise HTTPException(status_code=500, detail=f"识别失败: {str(e)}")


@app.post("/api/ocr/document")
async def ocr_document(file: UploadFile = File(...)):
    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="请上传图片文件")

    image_bytes = await file.read()
    if len(image_bytes) > 20 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="图片大小不能超过 20MB")

    try:
        result = ocr_service.parse_document(image_bytes)
        logger.info(f"文档解析完成: {result['element_count']} 个元素, 耗时 {result['elapsed_ms']}ms")
        return result
    except Exception as e:
        logger.exception("文档解析失败")
        raise HTTPException(status_code=500, detail=f"解析失败: {str(e)}")


@app.post("/api/ocr/auto")
async def ocr_auto(
    file: UploadFile = File(...),
    mode: str = Form(default="auto"),
):
    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="请上传图片文件")

    image_bytes = await file.read()

    try:
        if mode == "text":
            return ocr_service.recognize_text(image_bytes)
        elif mode == "document":
            return ocr_service.parse_document(image_bytes)
        else:
            try:
                return ocr_service.parse_document(image_bytes)
            except Exception:
                return ocr_service.recognize_text(image_bytes)
    except Exception as e:
        logger.exception("识别失败")
        raise HTTPException(status_code=500, detail=f"识别失败: {str(e)}")


@app.get("/")
async def index():
    return FileResponse(FRONTEND_DIR / "index.html")


app.mount("/static", StaticFiles(directory=str(FRONTEND_DIR)), name="static")


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8000))
    host = os.environ.get("HOST", "0.0.0.0")
    logger.info(f"词慧 OCR 服务启动: http://{host}:{port}")
    uvicorn.run(app, host=host, port=port)

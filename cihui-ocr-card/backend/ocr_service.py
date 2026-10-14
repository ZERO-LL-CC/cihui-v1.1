"""
PaddleOCR 服务封装
为词慧 App 提供文字识别、文档解析、表格识别等能力
"""
import os
import io
import time
import logging
from typing import Optional
from PIL import Image
import numpy as np

logger = logging.getLogger(__name__)


class OCRService:
    """PaddleOCR 服务单例，懒加载模型"""

    _instance: Optional["OCRService"] = None
    _ocr_engine = None
    _doc_parser = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    @property
    def ocr_engine(self):
        """通用 OCR 引擎（懒加载）"""
        if self._ocr_engine is None:
            logger.info("正在加载通用 OCR 模型...")
            from paddleocr import PaddleOCR
            self._ocr_engine = PaddleOCR(
                lang="ch",
                enable_mkldnn=False,
                use_doc_orientation_classify=True,
                use_doc_unwarping=True,
                use_textline_orientation=True,
            )
            logger.info("通用 OCR 模型加载完成")
        return self._ocr_engine

    @property
    def doc_parser_engine(self):
        """文档解析引擎（懒加载，支持表格/公式/版面分析）"""
        if self._doc_parser is None:
            logger.info("正在加载文档解析模型...")
            from paddleocr import PaddleOCR
            self._doc_parser = PaddleOCR(
                pipeline="doc_parser",
                enable_mkldnn=False,
            )
            logger.info("文档解析模型加载完成")
        return self._doc_parser

    def _load_image(self, image_bytes: bytes) -> np.ndarray:
        """将图片字节流加载为 numpy 数组"""
        img = Image.open(io.BytesIO(image_bytes))
        if img.mode != "RGB":
            img = img.convert("RGB")
        return np.array(img)

    def recognize_text(self, image_bytes: bytes) -> dict:
        """通用文字识别"""
        start_time = time.time()
        img_array = self._load_image(image_bytes)

        results = self.ocr_engine.predict(img_array)

        lines = []
        all_text = []
        for result in results:
            texts = result.get("rec_texts", [])
            scores = result.get("rec_scores", [])
            boxes = result.get("rec_polys", [])

            for i, (text, score) in enumerate(zip(texts, scores)):
                box = []
                if i < len(boxes):
                    box_data = boxes[i]
                    if hasattr(box_data, "tolist"):
                        box = box_data.tolist()
                    else:
                        box = list(box_data)
                lines.append({
                    "text": text,
                    "confidence": round(float(score), 4),
                    "box": box,
                })
                all_text.append(text)

        elapsed = round((time.time() - start_time) * 1000, 2)

        return {
            "success": True,
            "mode": "text_ocr",
            "full_text": "\n".join(all_text),
            "lines": lines,
            "line_count": len(lines),
            "elapsed_ms": elapsed,
        }

    def parse_document(self, image_bytes: bytes) -> dict:
        """文档解析（版面分析、表格、公式、印章等）"""
        start_time = time.time()
        img_array = self._load_image(image_bytes)

        try:
            results = self.doc_parser_engine.predict(img_array)
        except Exception as e:
            logger.warning(f"文档解析引擎失败，回退到通用 OCR: {e}")
            return self.recognize_text(image_bytes)

        markdown_parts = []
        elements = []
        tables = []
        formulas = []

        for result in results:
            markdown = result.get("markdown", None)
            if markdown:
                markdown_parts.append(markdown)

            layout_dets = result.get("layout_det", None)
            if layout_dets is not None:
                labels = result.get("layout_labels", [])
                scores = result.get("layout_scores", [])
                boxes = result.get("layout_polys", [])
                for i, label in enumerate(labels):
                    box = boxes[i].tolist() if i < len(boxes) and hasattr(boxes[i], "tolist") else []
                    elements.append({
                        "type": str(label),
                        "confidence": round(float(scores[i]), 4) if i < len(scores) else 0,
                        "box": box,
                    })
                    label_str = str(label).lower()
                    if "table" in label_str:
                        tables.append({"type": "table", "box": box})
                    elif "formula" in label_str or "equation" in label_str:
                        formulas.append({"type": "formula", "box": box})

        elapsed = round((time.time() - start_time) * 1000, 2)

        return {
            "success": True,
            "mode": "document_parse",
            "markdown": "\n".join(markdown_parts) if markdown_parts else "",
            "elements": elements,
            "tables": tables,
            "formulas": formulas,
            "element_count": len(elements),
            "elapsed_ms": elapsed,
        }

    def health_check(self) -> dict:
        """服务健康检查"""
        return {
            "status": "healthy",
            "engine": "PaddleOCR",
            "text_ocr_loaded": self._ocr_engine is not None,
            "doc_parser_loaded": self._doc_parser is not None,
        }

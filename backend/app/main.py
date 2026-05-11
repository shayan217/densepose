from __future__ import annotations

import base64
import logging
import time
from dataclasses import dataclass
from typing import Any

import cv2
import mediapipe as mp
import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware


logger = logging.getLogger("dense_pose.backend")
app = FastAPI(title="Dense Pose Lab Backend", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


LANDMARK_NAMES = [landmark.name.lower() for landmark in mp.solutions.pose.PoseLandmark]


@dataclass
class PoseEstimator:
    min_detection_confidence: float = 0.55
    min_tracking_confidence: float = 0.55
    model_complexity: int = 1

    def __post_init__(self) -> None:
        self._pose = mp.solutions.pose.Pose(
            static_image_mode=False,
            model_complexity=self.model_complexity,
            smooth_landmarks=True,
            enable_segmentation=False,
            min_detection_confidence=self.min_detection_confidence,
            min_tracking_confidence=self.min_tracking_confidence,
        )

    def estimate(self, bgr_frame: np.ndarray) -> list[dict[str, Any]]:
        rgb_frame = cv2.cvtColor(bgr_frame, cv2.COLOR_BGR2RGB)
        rgb_frame.flags.writeable = False
        result = self._pose.process(rgb_frame)

        if not result.pose_landmarks:
            return []

        landmarks = []
        for index, landmark in enumerate(result.pose_landmarks.landmark):
            landmarks.append(
                {
                    "index": index,
                    "name": LANDMARK_NAMES[index],
                    "x": float(landmark.x),
                    "y": float(landmark.y),
                    "z": float(landmark.z),
                    "visibility": float(landmark.visibility),
                }
            )

        return [{"id": 0, "landmarks": landmarks}]


estimator = PoseEstimator()


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "model": "mediapipe_pose"}


@app.get("/models")
def models() -> dict[str, Any]:
    return {
        "active": "mediapipe_pose",
        "available": [
            {
                "id": "mediapipe_pose",
                "type": "33_landmark_pose",
                "multi_person": False,
                "notes": "Fast real-time baseline with normalized x/y/z landmarks.",
            },
            {
                "id": "densepose",
                "type": "surface_correspondence",
                "multi_person": True,
                "notes": "Recommended as a future Detectron2 service when dense body UV maps are required.",
            },
        ],
    }


@app.websocket("/ws/pose")
async def pose_socket(websocket: WebSocket) -> None:
    await websocket.accept()
    logger.info("WebSocket connected: %s", websocket.client)
    frame_count = 0
    fps_started_at = time.perf_counter()
    smoothed_fps = 0.0

    try:
        while True:
            payload = await websocket.receive_json()
            if payload.get("type") != "frame":
                logger.warning("Unexpected WebSocket payload from %s", websocket.client)
                await websocket.send_json({"type": "error", "message": "Expected frame payload"})
                continue

            try:
                frame = decode_frame(payload.get("image", ""))
            except ValueError as error:
                logger.warning("Frame decode failed from %s: %s", websocket.client, error)
                await websocket.send_json({"type": "error", "message": str(error)})
                continue
            people = estimator.estimate(frame)
            frame_count += 1

            elapsed = time.perf_counter() - fps_started_at
            if elapsed >= 1:
                current_fps = frame_count / elapsed
                smoothed_fps = (
                    current_fps if smoothed_fps == 0 else smoothed_fps * 0.7 + current_fps * 0.3
                )
                frame_count = 0
                fps_started_at = time.perf_counter()
                logger.info(
                    "Processed frames from %s: fps=%.2f people=%d frame=%dx%d",
                    websocket.client,
                    smoothed_fps,
                    len(people),
                    frame.shape[1],
                    frame.shape[0],
                )

            await websocket.send_json(
                {
                    "type": "pose",
                    "model": "mediapipe_pose",
                    "fps": round(smoothed_fps, 2),
                    "people": people,
                    "timestamp": payload.get("timestamp"),
                }
            )
    except WebSocketDisconnect:
        logger.info("WebSocket disconnected: %s", websocket.client)
        return


def decode_frame(encoded_image: str) -> np.ndarray:
    try:
        frame_bytes = base64.b64decode(encoded_image)
    except ValueError as error:
        raise ValueError("Frame image is not valid base64") from error

    buffer = np.frombuffer(frame_bytes, dtype=np.uint8)
    frame = cv2.imdecode(buffer, cv2.IMREAD_COLOR)
    if frame is None:
        raise ValueError("Frame image could not be decoded")
    return frame
